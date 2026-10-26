/**
Committed and edited package assets.

Finds (1) git-tracked files under the fetch cache, (2) package files committed
elsewhere, matched by hash, and edited copies, matched by relative path or
file name plus high content similarity, (3) cached files whose hash doesn't
match the lockfile, and (4) a missing `.antorareg/cache/` ignore line.
Ejected packages and files under `ui.supplemental_files` are exempt and
listed as info.
*/
module antorareg.audit;

import std.algorithm : canFind, startsWith, endsWith, max, sort, map, filter;
import std.array : array, replace, split, join;
import std.conv : to;
import std.file;
import std.path : buildPath, baseName;
import std.string : splitLines, strip, stripLeft, stripRight;
import antorareg.fetch : fileSha256, hexSha, listTree, run;
import antorareg.lockfile;

enum Severity : string { error = "error", warn = "warn", info = "info" }

struct Finding
{
    Severity severity;
    string kind;    /// tracked-cache | committed-copy | modified-copy | cache-mismatch | gitignore | exempt
    string pkg;     /// id@version, or null
    string pkgPath; /// file inside the package
    string file;    /// repo file, relative to the repo root
    string detail;
    string advice;
}

/// One package file the lockfile knows.
struct PkgFile
{
    string id, version_, path, sha;
    bool vendored;
}

PkgFile[] packageFiles(const Lockfile lf)
{
    PkgFile[] r;
    foreach (e; lf.packages) foreach (f; e.files) r ~= PkgFile(e.id, e.version_, f[0], f[1], e.vendored);
    return r;
}

/// Line-based Dice similarity of two texts, 0..1.
double similarity(string a, string b)
{
    auto x = a.replace("\r\n", "\n").splitLines, y = b.replace("\r\n", "\n").splitLines;
    if (x.length + y.length == 0) return 1;
    size_t[string] cnt;
    foreach (l; x) cnt[l.strip]++;
    size_t common;
    foreach (l; y)
    {
        auto k = l.strip;
        if (auto p = k in cnt) if (*p) { (*p)--; common++; }
    }
    return 2.0 * common / (x.length + y.length);
}

enum double similarThreshold = 0.6;

private bool isText(const(ubyte)[] d)
{
    foreach (c; d[0 .. d.length < 4096 ? d.length : 4096]) if (c == 0) return false;
    return true;
}

private bool underAny(string file, const string[] dirs)
{
    foreach (d; dirs)
    {
        auto p = d.replace("\\", "/");
        while (p.startsWith("./")) p = p[2 .. $];
        while (p.endsWith("/")) p = p[0 .. $ - 1];
        if (p.length && (file == p || file.startsWith(p ~ "/"))) return true;
    }
    return false;
}

/// Names too generic to match on alone.
private immutable string[] genericNames = ["package.json", "README.adoc", "README.md", "LICENSE", "CHANGELOG.adoc",
    "CHANGELOG.md", "index.js", ".gitignore", "antora-registry.md"];

/**
Match tracked repo files against package files.
`tracked` are repo-relative paths; `readRepo` and `readPkg` return file bytes
(readPkg may return null when the package file isn't available locally).
*/
Finding[] matchCopies(const string[] tracked, const PkgFile[] pkgs, string cacheRel, const string[] exemptDirs,
    const string[] vendoredDirs, const(ubyte)[] delegate(string) readRepo,
    const(ubyte)[] delegate(const PkgFile) readPkg)
{
    Finding[] r;
    const(PkgFile)[][string] bySha, byName;
    foreach (ref p; pkgs) { bySha[p.sha] ~= p; byName[baseName(p.path)] ~= p; }
    foreach (f; tracked)
    {
        if (underAny(f, [cacheRel])) continue; // reported separately
        auto bn = baseName(f);
        bool exact;
        auto data = readRepo(f);
        if (data is null) continue;
        auto sha = hexSha(data);
        void add(Severity sev, string kind, const PkgFile p, string detail)
        {
            bool ej = underAny(f, vendoredDirs), sup = underAny(f, exemptDirs);
            auto pk = p.id ~ "@" ~ p.version_;
            if (ej || sup || p.vendored)
                r ~= Finding(Severity.info, "exempt", pk, p.path, f,
                    (ej || p.vendored ? "ejected package file" : "deliberate override in supplemental_files") ~ ": " ~ detail, null);
            else
                r ~= Finding(sev, kind, pk, p.path, f, detail,
                    "run `antorareg eject " ~ p.id ~ "` to own the package source, or move the change into the "
                    ~ "ui.supplemental_files folder");
        }
        if (auto hits = sha in bySha)
        {
            auto p = (*hits)[0];
            add(Severity.error, "committed-copy", p, "committed copy of " ~ p.id ~ "@" ~ p.version_ ~ ":" ~ p.path);
            continue;
        }
        if (!isText(data)) continue;
        // generic names (index.js, package.json) only count when the package-relative path matches too
        bool generic = genericNames.canFind(bn);
        auto cands = bn in byName;
        if (!cands) continue;
        // prefer a candidate whose relative path is a suffix of the repo path
        auto sorted = (*cands).dup;
        sorted.sort!((a, b) => f.endsWith(a.path) > f.endsWith(b.path));
        foreach (p; sorted)
        {
            if (generic && !(p.path.canFind("/") && (f == p.path || f.endsWith("/" ~ p.path)))) continue;
            auto pd = readPkg(p);
            if (pd is null || pd.length < 64) continue;
            auto sim = similarity(cast(string) data, cast(string) pd);
            if (sim >= similarThreshold)
            {
                add(Severity.error, "modified-copy", p, "modified copy of " ~ p.id ~ "@" ~ p.version_ ~ ":" ~ p.path
                    ~ " (" ~ (cast(int)(sim * 100)).to!string ~ "% similar)");
                break;
            }
        }
    }
    return r;
}

/// Tracked files under the cache folder.
Finding[] trackedCache(const string[] tracked, string cacheRel)
{
    Finding[] r;
    foreach (f; tracked)
        if (underAny(f, [cacheRel]))
            r ~= Finding(Severity.error, "tracked-cache", null, null, f, "git tracks a file in the fetch cache",
                "run `git rm -r --cached " ~ cacheRel ~ "` and keep `.antorareg/cache/` in .gitignore");
    return r;
}

/// Cached files whose hash doesn't match the lockfile (missing, changed or extra). Returns the IDs to fetch again.
Finding[] cacheMismatches(const Lockfile lf, string baseDir, string cacheDir, out string[] refetch)
{
    Finding[] r;
    foreach (e; lf.packages)
    {
        if (e.vendored || !e.files.length) continue;
        auto dir = buildPath(baseDir, cacheDir, e.id);
        if (!exists(dir)) continue; // drift reports a missing cache
        bool bad;
        bool[string] known;
        foreach (f; e.files)
        {
            known[f[0]] = true;
            auto p = buildPath(dir, f[0]);
            if (!exists(p)) { bad = true; r ~= mm(e, f[0], "missing from the cache"); }
            else if (fileSha256(p) != f[1]) { bad = true; r ~= mm(e, f[0], "hash does not match the lockfile"); }
        }
        foreach (rel; listTree(dir))
            if (rel !in known) { bad = true; r ~= mm(e, rel, "not in the lockfile"); }
        if (bad) refetch ~= e.id;
    }
    return r;
}

private Finding mm(const LockEntry e, string rel, string why)
{
    return Finding(Severity.warn, "cache-mismatch", e.id ~ "@" ~ e.version_, rel, ".antorareg/cache/" ~ e.id ~ "/" ~ rel,
        why ~ "; fetched again", "edit theme files through ui.supplemental_files, or run `antorareg eject " ~ e.id ~ "`");
}

// ------------------------------------------------------------- .gitignore

enum ignoreLine = ".antorareg/cache/";

/// True when the text ignores the cache at `line` (repo-relative, trailing slash), or ignores every `.antorareg` folder.
bool ignoresCache(string text, string line = ignoreLine)
{
    auto bare = line.endsWith("/") ? line[0 .. $ - 1] : line;
    foreach (l; text.splitLines)
    {
        auto s = l.strip;
        if (s == line || s == "/" ~ line || s == bare || s == "/" ~ bare || s == line ~ "**"
            || s == ".antorareg/" || s == ".antorareg" || s == "**/.antorareg/cache/" || s == "**/.antorareg/cache")
            return true;
        // a parent folder of the cache
        if (bare.startsWith(s.stripLeft("/").stripRight("/") ~ "/") && s.stripLeft("/").stripRight("/").canFind(".antorareg"))
            return true;
    }
    return false;
}

/// Append the ignore line, keeping content and line endings; no marker comments.
string withIgnoreLine(string text, string line = ignoreLine)
{
    if (ignoresCache(text, line)) return text;
    auto nl = text.canFind("\r\n") ? "\r\n" : "\n";
    if (text.length && !text.endsWith("\n")) text ~= nl;
    return text ~ line ~ nl;
}

/// Make sure `<repoRoot>/.gitignore` ignores the cache. Returns true when it changed.
bool ensureGitignore(string repoRoot, string line = ignoreLine)
{
    auto p = buildPath(repoRoot, ".gitignore");
    auto before = exists(p) ? readText(p) : "";
    auto after = withIgnoreLine(before, line);
    if (after == before) return false;
    write(p, after);
    return true;
}

Finding[] gitignoreFinding(string repoRoot, string line = ignoreLine)
{
    auto p = buildPath(repoRoot, ".gitignore");
    if (exists(p) && ignoresCache(readText(p), line)) return null;
    return [Finding(Severity.error, "gitignore", null, null, ".gitignore", "the repo-root .gitignore does not ignore "
        ~ line, "add the line `" ~ line ~ "` (antorareg install adds it on first install)")];
}

// ------------------------------------------------------------- git helpers

/// Repo root for `dir`, or null outside git.
string gitRoot(string dir)
{
    try return run(["git", "-C", dir, "rev-parse", "--show-toplevel"]).strip;
    catch (Exception) return null;
}

string[] gitTracked(string root)
{
    auto o = run(["git", "-C", root, "ls-files", "-z"]);
    return o.split("\0").filter!(s => s.length).array;
}

// ------------------------------------------------------------- tests

unittest // similarity
{
    assert(similarity("a\nb\nc\n", "a\nb\nc\n") == 1);
    assert(similarity("a\nb\nc\nd\n", "a\nb\nc\nX\n") == 0.75);
    assert(similarity("a\n", "z\n") == 0);
}

unittest // gitignore: append once, keep CRLF, no marker
{
    assert(withIgnoreLine("") == ".antorareg/cache/\n");
    assert(withIgnoreLine("node_modules/\r\nbuild/") == "node_modules/\r\nbuild/\r\n.antorareg/cache/\r\n");
    auto once = withIgnoreLine("node_modules/\n");
    assert(once == "node_modules/\n.antorareg/cache/\n");
    assert(withIgnoreLine(once) == once);
    assert(ignoresCache("/.antorareg/\n"));
    assert(!ignoresCache("# .antorareg/cache/\n"));
    // playbook in a subfolder: the root line does not cover it
    assert(!ignoresCache(".antorareg/cache/\n", "docs/.antorareg/cache/"));
    assert(ignoresCache("docs/.antorareg/\n", "docs/.antorareg/cache/"));
    assert(withIgnoreLine("x\n", "docs/.antorareg/cache/") == "x\ndocs/.antorareg/cache/\n");
}

version (unittest)
{
    private enum string css = "/* fingerprint */\n.a { color: red; }\n.b { color: blue; }\n.c { margin: 0; }\n"
        ~ ".d { padding: 0; }\n.e { display: none; }\n";

    private struct Fx
    {
        PkgFile[] pkgs;
        const(ubyte)[][string] repo;
        const(ubyte)[] readRepo(string f) { auto p = f in repo; return p ? *p : null; }
        const(ubyte)[] readPkg(const PkgFile p) { return p.path == "css/site.css" ? cast(const(ubyte)[]) css : null; }
    }

    private Fx fixture()
    {
        Fx fx;
        fx.pkgs = [PkgFile("github.com/o/r/theme", "1.0.0", "css/site.css", hexSha(cast(const(ubyte)[]) css))];
        return fx;
    }
}

unittest // (1) tracked cache files
{
    auto t = trackedCache(["docs/x.adoc", ".antorareg/cache/github.com/o/r/theme/css/site.css"], ".antorareg/cache");
    assert(t.length == 1 && t[0].kind == "tracked-cache" && t[0].severity == Severity.error);
}

unittest // (2a) exact committed copy, matched by hash under another name
{
    auto fx = fixture();
    fx.repo["assets/vendor/copied.css"] = cast(const(ubyte)[]) css;
    auto f = matchCopies(fx.repo.keys, fx.pkgs, ".antorareg/cache", [], [], &fx.readRepo, &fx.readPkg);
    assert(f.length == 1 && f[0].kind == "committed-copy" && f[0].pkg == "github.com/o/r/theme@1.0.0", f.to!string);
    assert(f[0].advice.canFind("antorareg eject github.com/o/r/theme") && f[0].advice.canFind("supplemental_files"));
}

unittest // (2b) edited copy, matched by name and similarity
{
    auto fx = fixture();
    fx.repo["ui/css/site.css"] = cast(const(ubyte)[]) css.replace("color: red", "color: green");
    fx.repo["other/site.css"] = cast(const(ubyte)[]) "body { font: 12px serif; }\n";
    auto f = matchCopies(fx.repo.keys, fx.pkgs, ".antorareg/cache", [], [], &fx.readRepo, &fx.readPkg);
    assert(f.length == 1 && f[0].file == "ui/css/site.css", f.to!string);
    assert(f[0].detail.startsWith("modified copy of github.com/o/r/theme@1.0.0:css/site.css"));
}

unittest // exempt: supplemental_files overrides and ejected folders are info
{
    auto fx = fixture();
    fx.repo["supplemental-ui/css/site.css"] = cast(const(ubyte)[]) css.replace("red", "teal");
    fx.repo["ui/theme/css/site.css"] = cast(const(ubyte)[]) css;
    auto f = matchCopies(fx.repo.keys, fx.pkgs, ".antorareg/cache", ["./supplemental-ui"], ["ui/theme"],
        &fx.readRepo, &fx.readPkg);
    assert(f.length == 2 && f[0].severity == Severity.info && f[1].severity == Severity.info, f.to!string);
}

unittest // (3) cache files that don't match the lockfile are reported and queued for refetch
{
    import antorareg.fetch : scratchDir, forceRemove;
    auto d = scratchDir("cm");
    scope (exit) forceRemove(d);
    auto pkg = buildPath(d, ".antorareg", "cache", "github.com", "o", "r", "theme", "css");
    mkdirRecurse(pkg);
    write(buildPath(pkg, "site.css"), css ~ "/* edited in place */\n");
    write(buildPath(pkg, "extra.css"), "x");
    Lockfile lf;
    LockEntry e = { id: "github.com/o/r/theme", version_: "1.0.0", surface: Surface.bundle };
    e.files = [["css/site.css", hexSha(cast(const(ubyte)[]) css)]];
    lf.put(e);
    string[] again;
    auto f = cacheMismatches(lf, d, ".antorareg/cache", again);
    assert(f.length == 2 && again == ["github.com/o/r/theme"], f.to!string);
    assert(f[0].severity == Severity.warn);
}

unittest // generic file names (index.js) match only when the package path matches too
{
    Fx fx;
    fx.pkgs = [PkgFile("github.com/o/r/ext", "1.0.0", "lib/index.js", "00")];
    struct R { const(ubyte)[] readPkg(const PkgFile p) { return cast(const(ubyte)[]) css; } }
    R r;
    fx.repo["vendor/ext/lib/index.js"] = cast(const(ubyte)[]) (css ~ "/* tweak */\n");
    fx.repo["src/index.js"] = cast(const(ubyte)[]) (css ~ "/* other */\n");
    auto f = matchCopies(fx.repo.keys, fx.pkgs, ".antorareg/cache", [], [], &fx.readRepo, &r.readPkg);
    assert(f.length == 1 && f[0].file == "vendor/ext/lib/index.js" && f[0].kind == "modified-copy", f.to!string);
}
