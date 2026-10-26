/// Command-line front end: argument parsing and the commands.
module antorareg.cli;

import std.algorithm : canFind, startsWith, endsWith, filter, map, sort, any, countUntil;
import std.array : array, join, replace, split;
import std.conv : to;
import std.exception : enforce;
import std.file;
static import std.file;
static import std.stdio;
import std.json;
import std.path;
import std.stdio;
import std.string : strip, toLower, indexOf;
import antorareg.audit;
import antorareg.config;
import antorareg.drift;
import antorareg.fetch;
import antorareg.lockfile;
import antorareg.pkgid;
import antorareg.playbook;
import antorareg.registry;
import antorareg.semver;

enum appVersion = "0.1.0-dev";
enum buildId = __DATE__ ~ " " ~ __TIME__ ~ ", " ~ __VENDOR__ ~ " " ~ __VERSION__.to!string;
enum antoraMajor = 3;

/// Exit codes: 0 ok, 1 failure/drift, 2 usage or ambiguous name, 3 conflict, 4 manual edit needed.
enum Exit { ok = 0, fail = 1, usage = 2, conflict = 3, manual = 4 }

struct Options
{
    string command;
    string[] args;
    string playbook;
    bool json, verbose, dryRun, offline, saveExact, replace, frozen, latest, yes, eject, help;
    int strict = -1; /// -1 unset (warn), 1 strict, 0 explicit --no-strict
    string source, surface, to;
}

class UsageError : Exception { this(string m, string file = __FILE__, size_t line = __LINE__) { super(m, file, line); } }

Options parseArgs(string[] argv)
{
    Options o;
    for (size_t i = 0; i < argv.length; i++)
    {
        auto a = argv[i];
        string val()
        {
            auto eq = a.indexOf('=');
            if (eq > 0) return a[eq + 1 .. $];
            enforce!UsageError(i + 1 < argv.length, a ~ " needs a value");
            return argv[++i];
        }
        auto name = a.indexOf('=') > 0 ? a[0 .. a.indexOf('=')] : a;
        switch (name)
        {
            case "--playbook": o.playbook = val(); break;
            case "--json": o.json = true; break;
            case "--verbose", "-v": o.verbose = true; break;
            case "--dry-run": o.dryRun = true; break;
            case "--offline": o.offline = true; break;
            case "--save-exact": o.saveExact = true; break;
            case "--replace": o.replace = true; break;
            case "--frozen": o.frozen = true; break;
            case "--latest": o.latest = true; break;
            case "--strict": o.strict = 1; break;
            case "--no-strict": o.strict = 0; break;
            case "--yes", "-y": o.yes = true; break;
            case "--eject": o.eject = true; break;
            case "--source": o.source = val(); break;
            case "--surface": o.surface = val(); break;
            case "--to": o.to = val(); break;
            case "--help", "-h": o.help = true; break;
            case "--version", "-V": o.command = "version"; break;
            default:
                enforce!UsageError(!a.startsWith("--"), "unknown option " ~ a);
                if (o.command is null) o.command = a; else o.args ~= a;
        }
    }
    if (o.source.length) enforce!UsageError(["git", "asset", "npm"].canFind(o.source), "--source must be git, asset or npm");
    enforce!UsageError(o.source != "npm", "--source npm is not implemented yet");
    if (o.surface.length) enforce!UsageError([cast(string) Surface.bundle, Surface.extension].canFind(o.surface),
        "--surface must be ui.bundle or antora.extensions");
    return o;
}

enum helpText = `antorareg ` ~ appVersion ~ ` - manage what an Antora 3 playbook pulls in, checked against the registry.
It never runs antora; keep running antora (or npx antora) yourself.

Usage: antorareg <command> [args] [options]

Commands:
  install [<id>[@<range>] ...]  Resolve, edit the playbook, write antorareg.lock, fetch into .antorareg/cache.
                                With no IDs, restore exactly what the lockfile pins (CI); --frozen fails on any change.
  update [<id> ...]             Newest version within the locked range (--latest: across majors).
                                Ejected packages are never overwritten; upstream changes are reported.
  list                          Packages, locked and newest versions, vendored status and drift.
  verify                        Checksums, playbook/lockfile drift, .gitignore and committed/edited package assets.
  eject <id> [--to <dir>]       Copy a package's source into the repo (default ui/<name>/) for direct edits.
  remove <id> ...               Remove the playbook entry and the lockfile entry.
  migrate [<id>[@<range>] ...]  One-time migration of an existing Antora 3 repo: match git-tracked files
                                against registry packages and print a plan. Applies only with a yes or --yes.
  init                          Create antorareg.lock and add .antorareg/cache/ to the repo .gitignore.
  debug-dump                    Versions, paths and config for bug reports (no secrets).
  help                          This text.

Package IDs: <host>/<owner>/<repo>/<package>, the short form <host>/<owner>/<repo>, the registry form
<owner>/<repo>/<package>, or a search term that matches exactly one package.

Options:
  --playbook <path>   Playbook (default: antora-playbook.yml here, then in parent folders)
  --json              Machine-readable output (list, verify)
  --dry-run           Show the diff; write nothing
  --offline           Never touch the network
  --verbose           More output
  --source git|asset  Where install fetches from (bundles always use release assets)
  --surface <key>     Force ui.bundle or antora.extensions
  --save-exact        Lock the exact version as the range
  --replace           Replace the active UI bundle
  --frozen            install: fail if the lockfile would change
  --latest            update: allow new majors
  --strict            verify: exit 1 on committed/edited asset findings (default: warn)
  --yes               migrate: apply without asking
  --eject             migrate: eject packages with modified copies instead of moving edits to supplemental_files
  --version           Version and build ID

Exit codes: 0 ok, 1 failure or drift, 2 usage or ambiguous name, 3 conflict, 4 manual playbook edit needed.
`;

struct Ctx
{
    Options o;
    Config cfg;
    string pbPath, base, lockPath, repoRoot;
    Playbook pb;
    Lockfile lf;
    string lockBefore;
    Module[] mods;
    bool modsLoaded;

    string cacheRelToRepo()
    {
        auto abs = buildNormalizedPath(base, cfg.cacheDir);
        return repoRoot.length ? relativePath(abs, repoRoot).replace("\\", "/") : cfg.cacheDir;
    }

    /// The .gitignore line for this playbook's cache, relative to the repo root.
    string ignoreLineHere()
    {
        auto r = cacheRelToRepo();
        while (r.startsWith("./")) r = r[2 .. $];
        return r.endsWith("/") ? r : r ~ "/";
    }

    Module[] catalog()
    {
        if (!modsLoaded)
        {
            mods = parseCatalog(loadCatalogText(cfg.registry, userCacheRoot(), o.offline));
            modsLoaded = true;
        }
        return mods;
    }
}

string findPlaybook(string given)
{
    if (given.length) { enforce(exists(given), "playbook not found: " ~ given); return absolutePath(given); }
    auto d = getcwd();
    while (true)
    {
        auto p = buildPath(d, "antora-playbook.yml");
        if (exists(p)) return p;
        auto up = dirName(d);
        if (up == d) break;
        d = up;
    }
    throw new Exception("no antora-playbook.yml here or in a parent folder; pass --playbook");
}

Ctx open(Options o)
{
    Ctx c;
    c.o = o;
    c.pbPath = findPlaybook(o.playbook);
    c.base = dirName(c.pbPath);
    c.cfg = loadConfig(c.base);
    c.lockPath = buildPath(c.base, "antorareg.lock");
    c.lf = Lockfile.load(c.lockPath);
    c.lf.playbook = baseName(c.pbPath);
    c.lockBefore = exists(c.lockPath) ? readText(c.lockPath) : "";
    c.pb = Playbook.load(c.pbPath);
    auto g = gitRoot(c.base);
    c.repoRoot = g.length ? buildNormalizedPath(g) : null;
    return c;
}

// ------------------------------------------------------------------ fetching

/// Fetch `e` into the cache; fills commit, sha256, files and entry.
void fetchPackage(ref Ctx c, ref LockEntry e)
{
    enforce(!c.o.offline, "--offline: " ~ e.id ~ " is not in the cache");
    auto rel = cacheRel(c.cfg.cacheDir, e.id);
    auto dest = buildPath(c.base, rel);
    forceRemove(dest);
    if (e.source == "git")
    {
        e.commit = gitFetch(e.url, e.ref_, e.subdir, dest);
        e.files = fileHashes(dest);
        e.sha256 = integrityOf(e.files);
    }
    else if (e.surface == Surface.bundle)
    {
        auto zip = buildPath(dest, "ui-bundle.zip");
        download(e.url, zip);
        extractZip(zip, buildPath(dest, "bundle"));
        e.sha256 = fileSha256(zip);
        e.files = fileHashes(dest);
    }
    else
    {
        auto tmp = scratchDir("asset");
        scope (exit) forceRemove(tmp);
        auto tgz = buildPath(tmp, "pkg.tgz");
        download(e.url, tgz);
        e.sha256 = fileSha256(tgz);
        extractTgz(tgz, dest, 1);
        e.files = fileHashes(dest);
    }
    if (e.surface == Surface.bundle) e.entry = e.url;
    else e.entry = "./" ~ rel ~ "/" ~ packageMain(dest);
}

/// True when the cache folder holds exactly the files the lockfile lists.
bool cacheIntact(ref Ctx c, const LockEntry e)
{
    auto dir = buildPath(c.base, cacheRel(c.cfg.cacheDir, e.id));
    if (!exists(dir) || !e.files.length) return false;
    auto have = fileHashes(dir);
    auto want = e.files.dup;
    want.sort!((a, b) => a[0] < b[0]);
    return have == want;
}

LockEntry planEntry(ref Ctx c, Module m, Release rel, string range)
{
    LockEntry e;
    e.id = m.pid.toString;
    auto v = rel.ver;
    e.version_ = v.toString;
    auto plain = v.major.to!string ~ "." ~ v.minor.to!string ~ "." ~ v.patch.to!string ~ (v.pre.length ? "-" ~ v.pre : "");
    e.range = c.o.saveExact ? plain : (range.length ? range : "^" ~ plain);
    e.surface = c.o.surface.length ? c.o.surface : (rel.hasBundle ? cast(string) Surface.bundle : cast(string) Surface.extension);
    e.ref_ = rel.tag;
    if (e.surface == Surface.bundle)
    {
        auto a = rel.assets.filter!(x => x.name == "ui-bundle.zip").array;
        enforce(a.length, e.id ~ "@" ~ e.version_ ~ " has no ui-bundle.zip release asset");
        e.source = "asset";
        e.url = a[0].url;
    }
    else
    {
        e.source = c.o.source.length ? c.o.source : c.cfg.source;
        if (e.source == "asset")
        {
            auto a = rel.assets.filter!(x => x.name.endsWith(".tgz")).array;
            enforce(a.length, e.id ~ "@" ~ e.version_ ~ " has no .tgz release asset; use --source git");
            e.url = a[0].url;
        }
        else
        {
            e.url = m.gitUrl;
            e.subdir = m.modulePath;
        }
    }
    return e;
}

/// Plan and apply one install to the in-memory playbook and lockfile.
int installOne(ref Ctx c, Module m, Release rel, string range)
{
    auto e = planEntry(c, m, rel, range);
    auto old = c.lf.find(e.id);
    if (old && old.vendored)
    {
        stderr.writeln(e.id, " is ejected (vendored at ", old.path, "); antorareg never overwrites it. See `antorareg update`.");
        return Exit.conflict;
    }
    string oldEntry = old ? old.entry : null;
    if (e.surface == Surface.bundle)
    {
        auto cur = c.pb.bundleUrl();
        string owner;
        foreach (x; c.lf.packages) if (x.surface == Surface.bundle && x.id != e.id) owner = x.id;
        bool foreign = cur.length && cur != oldEntry && cur != e.url;
        if ((foreign || owner.length) && !c.o.replace)
        {
            stderr.writeln("conflict: only one UI bundle can be active; the playbook uses ",
                owner.length ? owner : cur, ". Pass --replace to switch to ", e.id, ".");
            return Exit.conflict;
        }
        if (owner.length) c.lf.drop(owner);
    }
    writeln("fetching ", e.id, "@", e.version_, " (", e.source, ")");
    fetchPackage(c, e);
    if (e.surface == Surface.bundle)
    {
        c.pb.setBundle(e.entry);
        if (!c.pb.supplementalPath.length && !c.pb.doc.has("ui.supplemental_files"))
        {
            auto dir = c.pb.ensureSupplemental(c.cfg.supplementalDir);
            if (!c.o.dryRun)
            {
                auto abs = buildPath(c.base, dir);
                mkdirRecurse(abs);
                auto keep = buildPath(abs, ".gitkeep");
                if (!exists(keep)) std.file.write(keep, "");
            }
            writeln("theme overrides go in ", dir, " (ui.supplemental_files); the cache is never edited");
        }
    }
    else if (oldEntry.length) c.pb.replaceExtension(oldEntry, e.entry);
    else c.pb.addExtension(e.entry);
    c.lf.put(e);
    return Exit.ok;
}

/// Write playbook, lockfile and .gitignore, or show diffs on --dry-run.
void commitEdits(ref Ctx c, bool touchIgnore = true)
{
    auto lockText = c.lf.emit();
    if (c.o.dryRun)
    {
        std.stdio.write(unifiedDiff(c.pb.original, c.pb.emit(), baseName(c.pbPath)));
        std.stdio.write(unifiedDiff(c.lockBefore, lockText, "antorareg.lock"));
        writeln("(dry run: nothing written)");
        return;
    }
    if (c.pb.changed) c.pb.save();
    if (lockText != c.lockBefore)
    {
        std.file.write(c.lockPath ~ ".tmp", lockText);
        rename(c.lockPath ~ ".tmp", c.lockPath);
    }
    if (touchIgnore && ensureGitignore(c.repoRoot.length ? c.repoRoot : c.base, c.ignoreLineHere))
        writeln("added ", c.ignoreLineHere, " to .gitignore");
}

int manual(ManualEdit m)
{
    stderr.writeln("antorareg can't edit the playbook safely: ", m.msg);
    stderr.writeln("Nothing was written. Make this change by hand, then run `antorareg install` again:\n");
    stderr.writeln(m.instructions);
    return Exit.manual;
}

// ------------------------------------------------------------------ commands

int cmdInstall(ref Ctx c)
{
    if (c.o.args.length == 0) return cmdRestore(c);
    try
    {
        foreach (a; c.o.args)
        {
            string name, range;
            splitRange(a, name, range);
            auto m = resolve(c.catalog, name);
            auto rel = pick(m, range, antoraMajor);
            auto r = installOne(c, m, rel, range);
            if (r) return r;
        }
        commitEdits(c);
    }
    catch (ManualEdit m) return manual(m);
    return Exit.ok;
}

/// `install` with no IDs: restore exactly what the lockfile pins.
int cmdRestore(ref Ctx c)
{
    if (!exists(c.lockPath))
    {
        stderr.writeln("no antorareg.lock next to ", c.pbPath, c.o.frozen ? "; --frozen needs one" : "");
        return c.o.frozen ? Exit.fail : Exit.ok;
    }
    int bad;
    foreach (e; c.lf.packages)
    {
        if (e.vendored)
        {
            if (!exists(buildPath(c.base, e.path))) { stderr.writeln(e.id, ": vendored path ", e.path, " is missing"); bad++; }
            continue;
        }
        if (cacheIntact(c, e)) { if (c.o.verbose) writeln(e.id, ": cache ok"); continue; }
        if (e.source == "git" && !c.o.offline)
        {
            auto now = remoteTagCommit(e.url, e.ref_);
            if (now != e.commit)
            {
                stderr.writeln(e.id, ": tag ", e.ref_, " moved from ", e.commit, " to ", now.length ? now : "(gone)",
                    "; refusing to update silently");
                bad++;
                continue;
            }
        }
        auto got = e;
        writeln("fetching ", e.id, "@", e.version_);
        fetchPackage(c, got);
        if (got.sha256 != e.sha256 || got.commit != e.commit || got.entry != e.entry
            || (e.files.length && !cacheIntact(c, e)))
        {
            stderr.writeln(e.id, ": fetched content does not match the lockfile (sha256 ", got.sha256, " vs ", e.sha256, ")");
            bad++;
        }
    }
    if (bad) { stderr.writeln(bad, " package(s) don't match antorareg.lock; the lockfile was not changed"); return Exit.fail; }
    writeln("restored ", c.lf.packages.length, " package(s) from antorareg.lock");
    return Exit.ok;
}

int cmdUpdate(ref Ctx c)
{
    auto ids = c.o.args.length ? c.o.args : c.lf.packages.map!(e => e.id).array;
    try
    {
        foreach (id; ids)
        {
            auto e = c.lf.find(id);
            if (!e) { PackageId p; if (parseId(id, p)) e = c.lf.find(p.toString); }
            if (!e) { stderr.writeln(id, " is not in antorareg.lock"); return Exit.usage; }
            auto m = resolve(c.catalog, e.id);
            auto rel = pick(m, c.o.latest ? "" : e.range, antoraMajor);
            auto cur = SemVer.parse(e.version_);
            if (rel.ver <= cur) { writeln(e.id, " ", e.version_, " is up to date"); continue; }
            if (e.vendored)
            {
                writeln(e.id, " is ejected at ", e.path, " (upstream ", e.upstream, "); upstream has ", rel.ver.toString, ".");
                writeln("  compare upstream: git diff ", e.ref_.length ? e.ref_ : e.version_, " ", rel.tag,
                    e.subdir.length ? " -- " ~ e.subdir : "", "   (in a clone of ", m.repository, ")");
                writeln("  merge those changes into ", e.path, " by hand, then set `upstream` in antorareg.lock");
                continue;
            }
            auto savedSurface = c.o.surface;
            c.o.surface = e.surface;
            auto r = installOne(c, m, rel, c.o.latest ? null : e.range);
            c.o.surface = savedSurface;
            if (r) return r;
        }
        commitEdits(c);
    }
    catch (ManualEdit m) return manual(m);
    return Exit.ok;
}

int cmdList(ref Ctx c)
{
    auto drift = detectDrift(c.pb, c.lf, c.base, c.cfg.cacheDir);
    string[string] newest;
    if (!c.o.offline && c.lf.packages.length)
    {
        try
            foreach (e; c.lf.packages)
            {
                try newest[e.id] = pick(resolve(c.catalog, e.id), "", antoraMajor).ver.toString;
                catch (ResolveError) {}
            }
        catch (Exception x) stderr.writeln("registry unavailable: ", x.msg);
    }
    if (c.o.json)
    {
        JSONValue[] ps;
        foreach (e; c.lf.packages)
        {
            JSONValue j = ["id": e.id, "version": e.version_, "source": e.source, "surface": e.surface, "entry": e.entry];
            j["vendored"] = e.vendored;
            j["latest"] = newest.get(e.id, null);
            j["drift"] = drift.filter!(d => d.id == e.id).map!(d => JSONValue(["kind": cast(string) d.kind, "detail": d.detail])).array;
            ps ~= j;
        }
        JSONValue out_ = ["packages": ps];
        writeln(out_.toPrettyString);
        return drift.length ? Exit.fail : Exit.ok;
    }
    if (!c.lf.packages.length) writeln("no packages in antorareg.lock");
    foreach (e; c.lf.packages)
    {
        auto st = drift.filter!(d => d.id == e.id).map!(d => cast(string) d.kind).join(",");
        writefln("%s  %s%s  %s  %s%s  [%s]", e.id, e.version_, (e.id in newest && newest[e.id] != e.version_)
            ? " (newest " ~ newest[e.id] ~ ")" : "", e.surface, e.source, e.vendored ? "  vendored:" ~ e.path : "",
            st.length ? st : "ok");
        foreach (d; drift.filter!(d => d.id == e.id)) writeln("    ", d.kind, ": ", d.detail);
    }
    return Exit.ok;
}

Finding[] assetFindings(ref Ctx c, out string[] refetch)
{
    Finding[] fs = cacheMismatches(c.lf, c.base, c.cfg.cacheDir, refetch);
    if (!c.repoRoot.length)
    {
        fs ~= Finding(Severity.info, "no-git", null, null, null, "not a git repository; skipped tracked-file checks", null);
        return fs;
    }
    fs ~= gitignoreFinding(c.repoRoot, c.ignoreLineHere);
    auto tracked = gitTracked(c.repoRoot);
    auto cr = c.cacheRelToRepo();
    fs ~= trackedCache(tracked, cr);
    string toRepo(string p) { return c.repoRoot.length ? relativePath(buildNormalizedPath(c.base, p), c.repoRoot).replace("\\", "/") : p; }
    string[] exempt, vendored;
    auto sup = c.pb.supplementalPath();
    if (sup.length) exempt ~= toRepo(sup);
    foreach (e; c.lf.packages) if (e.vendored && e.path.length) vendored ~= toRepo(e.path);
    auto pkgs = packageFiles(c.lf);
    auto root = c.repoRoot;
    const(ubyte)[] readRepo(string f)
    {
        auto p = buildPath(root, f);
        if (!exists(p) || !isFile(p) || getSize(p) > 8 * 1024 * 1024) return null;
        return cast(const(ubyte)[]) read(p);
    }
    const(ubyte)[] readPkg(const PkgFile pf)
    {
        auto p = buildPath(c.base, cacheRel(c.cfg.cacheDir, pf.id), pf.path);
        return exists(p) ? cast(const(ubyte)[]) read(p) : null;
    }
    fs ~= matchCopies(tracked, pkgs, cr, exempt, vendored, &readRepo, &readPkg);
    return fs;
}

int cmdVerify(ref Ctx c)
{
    int code = Exit.ok;
    string[] lines;
    // checksums of cached artifacts first, so edited cache files are fetched again
    string[] refetch;
    auto findings = assetFindings(c, refetch);
    foreach (id; refetch)
    {
        auto e = *c.lf.find(id);
        if (c.o.offline) { lines ~= "error: " ~ id ~ ": cache does not match the lockfile (offline, not fetched)"; code = Exit.fail; continue; }
        auto got = e;
        fetchPackage(c, got);
        if (got.sha256 != e.sha256 || !cacheIntact(c, e))
        {
            lines ~= "error: " ~ id ~ ": fetched content does not match the lockfile sha256";
            code = Exit.fail;
        }
    }
    auto drift = detectDrift(c.pb, c.lf, c.base, c.cfg.cacheDir);
    foreach (e; c.lf.packages)
    {
        if (e.vendored || refetch.canFind(e.id)) continue;
        auto dir = buildPath(c.base, cacheRel(c.cfg.cacheDir, e.id));
        if (!exists(dir)) continue;
        auto sha = e.surface == Surface.bundle ? fileSha256(buildPath(dir, "ui-bundle.zip"))
            : (e.source == "git" ? treeSha256(dir) : e.sha256);
        if (sha != e.sha256) { lines ~= "error: " ~ e.id ~ ": checksum " ~ sha ~ " does not match the lockfile"; code = Exit.fail; }
    }
    foreach (d; drift) { lines ~= "drift: " ~ d.id ~ ": " ~ cast(string) d.kind ~ ": " ~ d.detail; code = Exit.fail; }
    bool strict = c.o.strict == 1;
    size_t problems;
    foreach (f; findings)
    {
        if (f.severity != Severity.info) problems++;
        auto lvl = f.severity == Severity.info ? "info" : (strict ? "error" : "warning");
        lines ~= lvl ~ ": " ~ f.kind ~ ": " ~ (f.file.length ? f.file ~ ": " : "") ~ f.detail
            ~ (f.pkg.length ? " [package " ~ f.pkg ~ "]" : "") ~ (f.advice.length ? "\n    -> " ~ f.advice : "");
    }
    if (strict && problems) code = Exit.fail;
    if (c.o.json)
    {
        JSONValue j = ["ok": JSONValue(code == Exit.ok)];
        j["drift"] = drift.map!(d => JSONValue(["id": d.id, "kind": cast(string) d.kind, "detail": d.detail])).array;
        j["findings"] = findings.map!(f => JSONValue(["severity": cast(string) f.severity, "kind": f.kind, "package": f.pkg,
            "packagePath": f.pkgPath, "file": f.file, "detail": f.detail, "advice": f.advice])).array;
        j["messages"] = lines;
        writeln(j.toPrettyString);
    }
    else
    {
        foreach (l; lines) (l.startsWith("info") ? stdout : stderr).writeln(l);
        writeln(code == Exit.ok ? "verify: ok" : "verify: failed", " (", c.lf.packages.length, " package(s), ",
            drift.length, " drift, ", problems, " asset finding(s)", strict ? ", strict" : "", ")");
    }
    return code;
}

int cmdEject(ref Ctx c)
{
    enforce!UsageError(c.o.args.length == 1, "usage: antorareg eject <id> [--to <dir>]");
    auto e = findEntry(c, c.o.args[0]);
    if (!e) { stderr.writeln(c.o.args[0], " is not in antorareg.lock; install it first"); return Exit.usage; }
    if (e.vendored) { writeln(e.id, " is already ejected at ", e.path); return Exit.ok; }
    if (!cacheIntact(c, *e)) { auto got = *e; fetchPackage(c, got); }
    auto name = e.id.split("/")[$ - 1];
    auto rel = (c.o.to.length ? c.o.to : c.cfg.vendorDir ~ "/" ~ name).replace("\\", "/");
    while (rel.startsWith("./")) rel = rel[2 .. $];
    auto dst = buildPath(c.base, rel);
    if (exists(dst)) { stderr.writeln(rel, " already exists; pick another folder with --to"); return Exit.conflict; }
    auto src = buildPath(c.base, cacheRel(c.cfg.cacheDir, e.id));
    try
    {
        string entry;
        if (e.surface == Surface.bundle) { entry = "./" ~ rel; c.pb.setBundle(entry); }
        else { entry = "./" ~ rel ~ "/" ~ packageMain(src); c.pb.replaceExtension(e.entry, entry); }
        if (!c.o.dryRun) copyTree(e.surface == Surface.bundle ? buildPath(src, "bundle") : src, dst);
        e.upstream = e.version_ ~ "@" ~ (e.commit.length ? e.commit : e.sha256);
        e.vendored = true;
        e.path = rel;
        e.entry = entry;
        if (!c.o.dryRun) e.sha256 = treeSha256(dst);
        commitEdits(c, false);
    }
    catch (ManualEdit m) return manual(m);
    if (c.o.dryRun) return Exit.ok;
    writeln("ejected ", e.id, " to ", rel, "; it is your code now. `antorareg update` will report upstream changes.");
    return Exit.ok;
}

LockEntry* findEntry(ref Ctx c, string q)
{
    if (auto e = c.lf.find(q)) return e;
    PackageId p;
    if (parseId(q, p)) return c.lf.find(p.toString);
    foreach (ref e; c.lf.packages) if (e.id.endsWith("/" ~ q)) return &e;
    return null;
}

int cmdRemove(ref Ctx c)
{
    enforce!UsageError(c.o.args.length > 0, "usage: antorareg remove <id> ...");
    try
    {
        foreach (q; c.o.args)
        {
            auto e = findEntry(c, q);
            if (!e) { stderr.writeln(q, " is not in antorareg.lock"); return Exit.usage; }
            if (e.surface == Surface.bundle)
            {
                if (c.pb.bundleUrl == e.entry)
                    throw new ManualEdit("removing the only UI bundle would leave the playbook without one",
                        "Point ui.bundle.url in " ~ c.pbPath ~ " at another bundle (or install one with --replace).");
            }
            else c.pb.removeExtension(e.entry);
            auto id = e.id;
            c.lf.drop(id);
            if (!c.o.dryRun) forceRemove(buildPath(c.base, cacheRel(c.cfg.cacheDir, id)));
            writeln("removed ", id);
        }
        commitEdits(c, false);
    }
    catch (ManualEdit m) return manual(m);
    return Exit.ok;
}

int cmdInit(ref Ctx c)
{
    if (c.o.dryRun) { writeln("would create antorareg.lock and add ", c.ignoreLineHere, " to .gitignore"); return Exit.ok; }
    if (!exists(c.lockPath)) { std.file.write(c.lockPath, c.lf.emit()); writeln("created ", c.lockPath); }
    if (ensureGitignore(c.repoRoot.length ? c.repoRoot : c.base, c.ignoreLineHere)) writeln("added ", c.ignoreLineHere, " to .gitignore");
    return Exit.ok;
}

int cmdDebugDump(Options o)
{
    import std.process : environment;
    writeln("antorareg ", appVersion, " (", buildId, ")");
    version (Windows) writeln("os: windows"); else version (OSX) writeln("os: macos"); else version (linux) writeln("os: linux");
    else writeln("os: other");
    version (X86_64) writeln("arch: x64"); else version (AArch64) writeln("arch: arm64"); else writeln("arch: other");
    writeln("user config: ", userConfigFile());
    writeln("user cache: ", userCacheRoot());
    try
    {
        auto c = open(o);
        writeln("playbook: ", c.pbPath);
        writeln("lockfile: ", c.lockPath, exists(c.lockPath) ? "" : " (missing)");
        writeln("repo root: ", c.repoRoot.length ? c.repoRoot : "(not git)");
        writeln("registry: ", c.cfg.registry);
        writeln("source: ", c.cfg.source, "; cacheDir: ", c.cfg.cacheDir, "; vendorDir: ", c.cfg.vendorDir);
        writeln("packages: ", c.lf.packages.length);
    }
    catch (Exception e) writeln("playbook: (", e.msg, ")");
    foreach (k; ["ANTORAREG_REGISTRY", "ANTORAREG_SOURCE", "ANTORAREG_CACHE_DIR", "ANTORAREG_VENDOR_DIR"])
        writeln(k, ": ", environment.get(k, "(unset)"));
    foreach (k; ["GITHUB_TOKEN", "GH_TOKEN"]) writeln(k, ": ", environment.get(k) ? "(set, redacted)" : "(unset)");
    foreach (t; ["git", "curl"])
    {
        try writeln(t, ": ", run([t, "--version"]).split("\n")[0].strip);
        catch (Exception) writeln(t, ": not found");
    }
    return Exit.ok;
}

int runCli(string[] argv)
{
    Options o;
    try o = parseArgs(argv[1 .. $]);
    catch (UsageError e) { stderr.writeln("antorareg: ", e.msg, "\nRun `antorareg help`."); return Exit.usage; }
    if (o.command == "version") { writeln("antorareg ", appVersion, " (", buildId, ")"); return Exit.ok; }
    if (o.help || o.command is null || o.command == "help") { std.stdio.write(helpText); return o.command is null && !o.help ? Exit.usage : Exit.ok; }
    if (o.command == "debug-dump") return cmdDebugDump(o);
    try
    {
        auto known = ["install", "update", "list", "verify", "eject", "remove", "migrate", "init"];
        if (!known.canFind(o.command)) { stderr.writeln("antorareg: unknown command ", o.command, "\nRun `antorareg help`."); return Exit.usage; }
        auto c = open(o);
        switch (o.command)
        {
            case "install": return cmdInstall(c);
            case "update": return cmdUpdate(c);
            case "list": return cmdList(c);
            case "verify": return cmdVerify(c);
            case "eject": return cmdEject(c);
            case "remove": return cmdRemove(c);
            case "init": return cmdInit(c);
            case "migrate":
                import antorareg.migrate : cmdMigrate;
                return cmdMigrate(c);
            default: assert(0);
        }
    }
    catch (UsageError e) { stderr.writeln("antorareg: ", e.msg); return Exit.usage; }
    catch (ResolveError e) { stderr.writeln("antorareg: ", e.msg); return e.code; }
    catch (ManualEdit m) return manual(m);
    catch (Exception e) { stderr.writeln("antorareg: ", e.msg); return Exit.fail; }
}

unittest // argument parsing
{
    auto o = parseArgs(["install", "a/b/c@^1.0.0", "--playbook=x.yml", "--dry-run", "--source", "asset"]);
    assert(o.command == "install" && o.args == ["a/b/c@^1.0.0"] && o.playbook == "x.yml" && o.dryRun && o.source == "asset");
    assert(parseArgs(["verify", "--strict"]).strict == 1);
    bool threw;
    try parseArgs(["install", "--bogus"]); catch (UsageError) threw = true;
    assert(threw);
}
