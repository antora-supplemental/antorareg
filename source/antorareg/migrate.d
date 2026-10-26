/**
`antorareg migrate`: one-time migration of an existing Antora 3 repo.

Scans git-tracked files that look like UI or extension assets, matches them
against registry package files by hash (exact copies) and by name plus
similarity (modified copies), and prints a plan. Nothing changes until the
user answers yes (or passes `--yes`); `--dry-run` only prints. antorareg
never stages or commits: it deletes working-tree copies and prints the
`git rm --cached` commands for the user to run.
*/
module antorareg.migrate;

import std.algorithm : canFind, endsWith, startsWith, filter, map, sort, uniq;
import std.array : array, join, replace;
import std.file;
import std.path;
import std.stdio;
static import std.stdio;
static import std.file;
import std.string : strip, toLower;
import antorareg.audit;
import antorareg.cli;
import antorareg.drift : cacheRel;
import antorareg.fetch;
import antorareg.lockfile;
import antorareg.pkgid : splitRange;
import antorareg.playbook;
import antorareg.registry;

/// File kinds worth scanning: theme sources, bundles, partials, scripts, styles, fonts and images.
bool candidateFile(string f)
{
    auto l = f.toLower;
    foreach (d; ["supplemental", "ui/", "ui-bundle", "partials/", "vendor", "lib/", "extensions/"])
        if (l.canFind(d)) return true;
    foreach (x; [".css", ".js", ".cjs", ".mjs", ".hbs", ".handlebars", ".zip", ".svg", ".woff", ".woff2"])
        if (l.endsWith(x)) return true;
    return false;
}

struct PkgPlan
{
    LockEntry entry;
    Finding[] exact, modified;
}

/// Group findings by package and decide per package.
PkgPlan[] buildPlan(Finding[] fs, LockEntry[] entries)
{
    PkgPlan[] r;
    foreach (e; entries)
    {
        PkgPlan p;
        p.entry = e;
        auto key = e.id ~ "@" ~ e.version_;
        foreach (f; fs)
        {
            if (f.pkg != key) continue;
            if (f.kind == "committed-copy") p.exact ~= f;
            else if (f.kind == "modified-copy") p.modified ~= f;
        }
        // a file matched by an exact copy is not also a modified copy
        if (p.exact.length || p.modified.length) r ~= p;
    }
    return r;
}

/// Where a modified copy goes in supplemental_files (bundle files only).
string supplementalTarget(string pkgPath)
{
    return pkgPath.startsWith("bundle/") ? pkgPath["bundle/".length .. $] : null;
}

string[] describePlan(const PkgPlan[] plan, bool eject, string supDir)
{
    string[] o;
    foreach (p; plan)
    {
        auto e = p.entry;
        o ~= e.id ~ "@" ~ e.version_ ~ " (" ~ e.surface ~ ")";
        o ~= "  add to antorareg.lock and the playbook (" ~ e.entry ~ ")";
        foreach (f; p.exact) o ~= "  exact copy   " ~ f.file ~ "  -> delete; you run: git rm --cached \"" ~ f.file ~ "\"";
        foreach (f; p.modified)
        {
            if (eject) o ~= "  modified     " ~ f.file ~ "  -> keep the edit in the ejected copy (" ~ f.pkgPath ~ ")";
            else if (auto t = supplementalTarget(f.pkgPath))
                o ~= "  modified     " ~ f.file ~ "  -> move to " ~ supDir ~ "/" ~ t ~ " (supplemental_files override)";
            else
                o ~= "  modified     " ~ f.file ~ "  -> left in place; extension edits need --eject";
        }
    }
    return o;
}

bool confirm(string q)
{
    std.stdio.write(q, " [y/N] ");
    stdout.flush();
    if (stdin.eof) return false;
    auto a = stdin.readln.strip.toLower;
    return a == "y" || a == "yes";
}

int cmdMigrate(ref Ctx c)
{
    if (!c.repoRoot.length) { stderr.writeln("migrate needs a git repository (it scans tracked files)"); return Exit.fail; }
    // 1. candidates
    Module[] cands;
    string[string] ranges;
    if (c.o.args.length)
        foreach (a; c.o.args) { string n, r; splitRange(a, n, r); auto m = resolve(c.catalog, n); cands ~= m; ranges[m.catalogId] = r; }
    else cands = c.catalog;
    // 2. fetch each candidate into the (disposable) cache
    LockEntry[] entries;
    foreach (m; cands)
    {
        if (c.lf.find(m.pid.toString)) continue;
        Release rel;
        try rel = pick(m, ranges.get(m.catalogId, ""), antoraMajor);
        catch (Exception) continue;
        LockEntry e;
        try { e = planEntry(c, m, rel, ranges.get(m.catalogId, null)); fetchPackage(c, e); }
        catch (Exception x) { if (c.o.verbose) stderr.writeln("skip ", m.catalogId, ": ", x.msg); continue; }
        if (c.o.verbose) writeln("scanned ", e.id, "@", e.version_, " (", e.files.length, " files)");
        entries ~= e;
    }
    // 3. match tracked files
    auto tracked = gitTracked(c.repoRoot).filter!(f => candidateFile(f)).array;
    Lockfile tmp;
    tmp.packages = entries;
    auto cr = c.cacheRelToRepo();
    auto root = c.repoRoot;
    const(ubyte)[] readRepo(string f)
    {
        auto p = buildPath(root, f);
        return exists(p) && isFile(p) ? cast(const(ubyte)[]) read(p) : null;
    }
    const(ubyte)[] readPkg(const PkgFile pf)
    {
        auto p = buildPath(c.base, cacheRel(c.cfg.cacheDir, pf.id), pf.path);
        return exists(p) && isFile(p) ? cast(const(ubyte)[]) read(p) : null;
    }
    auto fs = matchCopies(tracked, packageFiles(tmp), cr, [], [], &readRepo, &readPkg);
    auto plan = buildPlan(fs, entries);
    // drop fetched caches for packages that matched nothing
    foreach (e; entries) if (!plan.canFind!(p => p.entry.id == e.id)) forceRemove(buildPath(c.base, cacheRel(c.cfg.cacheDir, e.id)));
    if (!plan.length) { writeln("migrate: no tracked files match registry packages (", tracked.length, " files checked)"); return Exit.ok; }
    auto sup = c.pb.supplementalPath.length ? c.pb.supplementalPath : c.cfg.supplementalDir;
    writeln("migrate plan:");
    foreach (l; describePlan(plan, c.o.eject, sup)) writeln("  ", l);
    if (c.o.dryRun) { writeln("(dry run: nothing changed)"); return Exit.ok; }
    if (!c.o.yes && !confirm("Apply this plan?")) { writeln("migrate: nothing changed"); return Exit.ok; }
    return applyPlan(c, plan, sup);
}

int applyPlan(ref Ctx c, PkgPlan[] plan, string sup)
{
    string[] rmCached, added;
    try
    {
        foreach (p; plan)
        {
            auto e = p.entry;
            if (e.surface == Surface.bundle)
            {
                c.pb.setBundle(e.entry);
                foreach (ref x; c.lf.packages) if (x.surface == Surface.bundle) { c.lf.drop(x.id); break; }
            }
            else
            {
                // replace a require: that pointed at a committed copy, else add
                string old;
                foreach (f; p.exact ~ p.modified)
                {
                    auto rel = "./" ~ relativePath(buildPath(c.repoRoot, f.file), c.base).replace("\\", "/");
                    if (c.pb.findExtension(rel) >= 0) old = rel;
                }
                if (old.length) c.pb.replaceExtension(old, e.entry); else c.pb.addExtension(e.entry);
            }
            c.lf.put(e);
        }
        if (c.pb.supplementalPath.length == 0 && plan.any!(p => p.entry.surface == Surface.bundle && p.modified.length) && !c.o.eject)
            sup = c.pb.ensureSupplemental(sup);
        commitEdits(c);
    }
    catch (ManualEdit m) return manual(m);
    foreach (p; plan)
    {
        foreach (f; p.exact) { remove(buildPath(c.repoRoot, f.file)); rmCached ~= f.file; }
        if (!p.modified.length) continue;
        if (c.o.eject)
        {
            c.o.args = [p.entry.id];
            c.o.to = null;
            auto r = cmdEject(c);
            if (r) return r;
            auto ej = c.lf.find(p.entry.id);
            foreach (f; p.modified)
            {
                auto inPkg = p.entry.surface == Surface.bundle ? supplementalTarget(f.pkgPath) : f.pkgPath;
                if (!inPkg.length) continue;
                auto dst = buildPath(c.base, ej.path, inPkg);
                mkdirRecurse(dirName(dst));
                copy(buildPath(c.repoRoot, f.file), dst);
                remove(buildPath(c.repoRoot, f.file));
                rmCached ~= f.file;
            }
            ej.sha256 = treeSha256(buildPath(c.base, ej.path));
            std.file.write(c.lockPath, c.lf.emit());
            added ~= ej.path;
        }
        else foreach (f; p.modified)
        {
            auto t = supplementalTarget(f.pkgPath);
            if (!t.length) continue;
            auto dst = buildPath(c.base, sup, t);
            mkdirRecurse(dirName(dst));
            copy(buildPath(c.repoRoot, f.file), dst);
            remove(buildPath(c.repoRoot, f.file));
            rmCached ~= f.file;
        }
    }
    writeln("migrate: done. antorareg does not stage or commit; review, then run:");
    foreach (f; rmCached) writeln("  git rm --cached --ignore-unmatch \"", f, "\"");
    if (!c.o.eject && plan.any!(p => p.modified.length && p.entry.surface == Surface.bundle)) added ~= sup;
    writeln("  git add antorareg.lock ", baseName(c.pbPath), " .gitignore", added.length ? " " ~ added.join(" ") : "");
    return Exit.ok;
}

private bool any(alias pred, R)(R r) { foreach (x; r) if (pred(x)) return true; return false; }

unittest // plan grouping and targets
{
    auto e = LockEntry("github.com/o/r/theme", "1.0.0");
    e.surface = Surface.bundle;
    e.entry = "https://x/ui-bundle.zip";
    auto fs = [Finding(Severity.error, "committed-copy", "github.com/o/r/theme@1.0.0", "bundle/css/site.css", "ui/css/site.css", "", ""),
        Finding(Severity.error, "modified-copy", "github.com/o/r/theme@1.0.0", "bundle/partials/header.hbs", "supp/header.hbs", "", ""),
        Finding(Severity.error, "committed-copy", "github.com/o/r/other@1.0.0", "x", "y", "", "")];
    auto p = buildPlan(fs, [e]);
    assert(p.length == 1 && p[0].exact.length == 1 && p[0].modified.length == 1);
    assert(supplementalTarget("bundle/partials/header.hbs") == "partials/header.hbs");
    assert(supplementalTarget("lib/index.js") is null);
    auto d = describePlan(p, false, "./supplemental-ui");
    assert(d.canFind!(l => l.canFind("git rm --cached \"ui/css/site.css\"")));
    assert(d.canFind!(l => l.canFind("./supplemental-ui/partials/header.hbs")));
    assert(candidateFile("supplemental-ui/css/x.css") && !candidateFile("docs/modules/ROOT/pages/index.adoc"));
}
