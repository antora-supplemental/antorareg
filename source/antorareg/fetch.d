/// Fetching: git shallow clones, HTTPS downloads, archive extraction and SHA-256 digests.
module antorareg.fetch;

import std.algorithm : sort, startsWith, endsWith, canFind;
import std.array : appender, replace;
import std.conv : to, octal;
import std.digest : toHexString, LetterCase;
import std.digest.sha : SHA256, sha256Of;
import std.exception : enforce;
import std.file;
import std.path;
import std.process : execute;
static import std.process;
import std.random : uniform;
import std.string : strip, indexOf, toLower;

/// Run a program (no shell). Throws with its output on failure.
string run(string[] args, string cwd = null)
{
    auto r = execute(args, null, std.process.Config.none, size_t.max, cwd);
    enforce(r.status == 0, args[0] ~ " failed (" ~ r.status.to!string ~ "): " ~ r.output.strip);
    return r.output;
}

string hexSha(const(ubyte)[] data)
{
    return toHexString!(LetterCase.lower)(sha256Of(data)).idup;
}

string fileSha256(string file)
{
    return hexSha(cast(const(ubyte)[]) read(file));
}

/// Files under `dir`, relative, with '/' separators, sorted. `.git` is skipped.
string[] listTree(string dir)
{
    string[] r;
    foreach (DirEntry e; dirEntries(dir, SpanMode.depth, false))
    {
        if (!e.isFile) continue;
        auto rel = relativePath(e.name, dir).replace("\\", "/");
        if (rel.startsWith(".git/") || rel == ".git") continue;
        r ~= rel;
    }
    r.sort();
    return r;
}

/// Per-file digests `[path, sha256]` of a tree.
string[2][] fileHashes(string dir)
{
    string[2][] r;
    foreach (rel; listTree(dir)) r ~= [rel, fileSha256(buildPath(dir, rel))];
    return r;
}

/// Package integrity: SHA-256 over `path\0sha\n` of every file, in path order.
string treeSha256(string dir)
{
    return integrityOf(fileHashes(dir));
}

string integrityOf(const string[2][] files)
{
    auto sorted = files.dup;
    sorted.sort!((a, b) => a[0] < b[0]);
    SHA256 h;
    foreach (f; sorted) { h.put(cast(const(ubyte)[]) f[0]); h.put(0); h.put(cast(const(ubyte)[]) f[1]); h.put('\n'); }
    return toHexString!(LetterCase.lower)(h.finish()).idup;
}

/// Remove a tree even when it holds read-only files (git packs on Windows).
void forceRemove(string p)
{
    if (!exists(p)) return;
    if (isFile(p)) { version (Windows) setAttributes(p, 0x80); remove(p); return; }
    version (Windows)
        foreach (DirEntry e; dirEntries(p, SpanMode.depth, false))
            if (e.isFile) setAttributes(e.name, 0x80); // FILE_ATTRIBUTE_NORMAL
    rmdirRecurse(p);
}

void copyTree(string src, string dst)
{
    mkdirRecurse(dst);
    foreach (rel; listTree(src))
    {
        auto t = buildPath(dst, rel);
        mkdirRecurse(dirName(t));
        copy(buildPath(src, rel), t);
        version (Windows) setAttributes(t, 0x80);
    }
}

string scratchDir(string tag)
{
    auto d = buildPath(tempDir, "antorareg-" ~ tag ~ "-" ~ uniform(0, int.max).to!string);
    mkdirRecurse(d);
    return d;
}

/// Download over HTTPS with curl. Plain HTTP is refused.
void download(string url, string dest)
{
    enforce(url.startsWith("https://"), "refusing non-HTTPS URL: " ~ url);
    mkdirRecurse(dirName(dest));
    run(["curl", "-fsSL", "--proto", "=https", "--retry", "2", "-o", dest, url]);
}

/// Shallow-clone `tag` and copy `subpath` (or the whole tree) into `dest`. Returns the commit SHA.
string gitFetch(string repoUrl, string tag, string subpath, string dest)
{
    auto tmp = scratchDir("git");
    scope (exit) forceRemove(tmp);
    auto co = buildPath(tmp, "co");
    auto commit = gitCheckout(repoUrl, tag, co);
    return copyFromCheckout(co, subpath, tag, dest, commit);
}

/// Shallow clone of one tag into `co` (line endings untouched). Returns the commit SHA.
string gitCheckout(string repoUrl, string tag, string co)
{
    run(["git", "-c", "core.autocrlf=false", "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1",
        "--branch", tag, repoUrl, co]);
    return run(["git", "-C", co, "rev-parse", "HEAD"]).strip;
}

string copyFromCheckout(string co, string subpath, string tag, string dest, string commit)
{
    auto src = subpath.length ? buildPath(co, subpath) : co;
    enforce(exists(src), "path " ~ subpath ~ " not found at " ~ tag);
    forceRemove(dest);
    copyTree(src, dest);
    return commit;
}

/// Commit a remote tag points at now (peeled), or null.
string remoteTagCommit(string repoUrl, string tag)
{
    auto o = run(["git", "ls-remote", "--tags", repoUrl, "refs/tags/" ~ tag, "refs/tags/" ~ tag ~ "^{}"]);
    string plain, peeled;
    foreach (line; o.splitLinesSimple)
    {
        auto t = line.indexOf('\t');
        if (t < 0) continue;
        if (line[t + 1 .. $].endsWith("^{}")) peeled = line[0 .. t]; else plain = line[0 .. t];
    }
    return peeled.length ? peeled : plain;
}

private string[] splitLinesSimple(string s)
{
    import std.string : splitLines;
    return s.splitLines;
}

/// Extract a .tgz (npm pack layout); `strip` drops that many leading path components.
void extractTgz(string file, string dest, int strip = 1)
{
    import std.zlib : UnCompress, HeaderFormat;
    auto u = new UnCompress(HeaderFormat.gzip);
    auto tar = cast(const(ubyte)[]) u.uncompress(read(file));
    tar ~= cast(const(ubyte)[]) u.flush();
    extractTar(tar, dest, strip);
}

void extractTar(const(ubyte)[] tar, string dest, int strip)
{
    size_t pos;
    string longName;
    while (pos + 512 <= tar.length)
    {
        auto h = tar[pos .. pos + 512];
        if (h[0] == 0) break;
        string field(size_t a, size_t b)
        {
            auto s = cast(string) h[a .. b];
            auto z = s.indexOf('\0');
            return (z >= 0 ? s[0 .. z] : s).idup;
        }
        auto name = field(0, 100);
        auto prefix = field(345, 500);
        if (prefix.length) name = prefix ~ "/" ~ name;
        auto sz = field(124, 136).strip;
        size_t size = sz.length ? sz.to!size_t(8) : 0;
        auto type = cast(char) h[156];
        pos += 512;
        auto data = tar[pos .. pos + size];
        pos += (size + 511) / 512 * 512;
        if (type == 'L') { longName = (cast(string) data).idup; auto z = longName.indexOf('\0'); if (z >= 0) longName = longName[0 .. z]; continue; }
        if (longName.length) { name = longName; longName = null; }
        if (type != '0' && type != '\0') continue; // regular files only; no links
        auto rel = safeRel(name, strip);
        if (rel is null) continue;
        auto t = buildPath(dest, rel);
        mkdirRecurse(dirName(t));
        write(t, data);
    }
}

/// Extract a zip, refusing paths that escape `dest`.
void extractZip(string file, string dest, int strip = 0)
{
    import std.zip : ZipArchive;
    auto z = new ZipArchive(read(file));
    foreach (name, m; z.directory)
    {
        if (name.endsWith("/")) continue;
        auto rel = safeRel(name, strip);
        if (rel is null) continue;
        auto t = buildPath(dest, rel);
        mkdirRecurse(dirName(t));
        write(t, z.expand(m));
    }
}

private string safeRel(string name, int strip)
{
    import std.array : split, join;
    auto parts = name.replace("\\", "/").split("/");
    string[] keep;
    foreach (p; parts) if (p.length && p != ".") keep ~= p;
    if (keep.length <= strip) return null;
    keep = keep[strip .. $];
    foreach (p; keep) if (p == "..") return null;
    return keep.join("/");
}

/// `main` from package.json in `dir` (default index.js), with '/' separators.
string packageMain(string dir)
{
    import std.json : parseJSON, JSONType;
    auto pj = buildPath(dir, "package.json");
    if (exists(pj))
    {
        auto j = parseJSON(readText(pj));
        if (auto m = "main" in j.object)
            if (m.type == JSONType.string) return m.str.replace("\\", "/").chompPrefixDot;
    }
    return "index.js";
}

private string chompPrefixDot(string s) { return s.startsWith("./") ? s[2 .. $] : s; }

unittest // tree digests depend only on paths and bytes
{
    auto d = scratchDir("t");
    scope (exit) forceRemove(d);
    mkdirRecurse(buildPath(d, "a", "lib"));
    write(buildPath(d, "a", "lib", "index.js"), "module.exports = 1\n");
    write(buildPath(d, "a", "package.json"), `{"main": "./lib/index.js"}`);
    auto h1 = treeSha256(buildPath(d, "a"));
    copyTree(buildPath(d, "a"), buildPath(d, "b"));
    assert(treeSha256(buildPath(d, "b")) == h1);
    assert(packageMain(buildPath(d, "b")) == "lib/index.js");
    assert(fileHashes(buildPath(d, "b"))[0][0] == "lib/index.js");
    write(buildPath(d, "b", "lib", "index.js"), "module.exports = 2\n");
    assert(treeSha256(buildPath(d, "b")) != h1);
}

unittest // tar extraction strips package/ and refuses traversal
{
    ubyte[] hdr(string name, size_t size)
    {
        auto h = new ubyte[512];
        h[0 .. name.length] = cast(const(ubyte)[]) name;
        import std.format : format;
        auto s = format("%011o", size);
        h[124 .. 124 + s.length] = cast(const(ubyte)[]) s;
        h[156] = '0';
        return h;
    }
    ubyte[] tar;
    tar ~= hdr("package/lib/x.js", 3); tar ~= cast(ubyte[]) "abc"; tar ~= new ubyte[509];
    tar ~= hdr("package/../../evil", 1); tar ~= cast(ubyte[]) "z"; tar ~= new ubyte[511];
    tar ~= new ubyte[1024];
    auto d = scratchDir("tar");
    scope (exit) forceRemove(d);
    extractTar(tar, d, 1);
    assert(readText(buildPath(d, "lib", "x.js")) == "abc");
    assert(listTree(d) == ["lib/x.js"]);
}
