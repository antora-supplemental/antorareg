/// `antorareg.lock`: the only record of what antorareg installed.
module antorareg.lockfile;

import std.algorithm : sort, countUntil, remove;
import std.array : appender;
import std.conv : to;
import std.file : exists, readText;
import yaml_edit;
import antorareg.yamlq;

enum Surface : string
{
    bundle = "ui.bundle",
    extension = "antora.extensions",
}

struct LockEntry
{
    string id;
    string version_;
    string range;
    string source;   /// git | asset
    string url;      /// repository URL (git) or asset URL (asset)
    string ref_;     /// git tag
    string subdir;   /// package folder inside the repository (git)
    string commit;   /// resolved commit SHA (git)
    string sha256;   /// asset digest or tree digest
    string surface;  /// Surface value
    string entry;    /// exact playbook value antorareg wrote (bundle URL or require path)
    bool vendored;
    string path;     /// vendored copy, relative to the playbook
    string upstream; /// version@commit the vendored copy came from
    string[2][] files; /// per-file [relative path, sha256] of the fetched package
}

struct Lockfile
{
    int lockfileVersion = 1;
    string playbook = "antora-playbook.yml";
    int antora = 3;
    LockEntry[] packages;

    static Lockfile load(string file)
    {
        if (!exists(file)) return Lockfile.init;
        return parse(readText(file));
    }

    static Lockfile parse(string text)
    {
        Lockfile lf;
        auto doc = Document.parse(text);
        lf.lockfileVersion = doc.get("lockfileVersion", "1").to!int;
        if (lf.lockfileVersion != 1)
            throw new Exception("unsupported lockfileVersion " ~ lf.lockfileVersion.to!string);
        lf.playbook = doc.get("playbook", lf.playbook);
        lf.antora = doc.get("antora", "3").to!int;
        if (!doc.has("packages") || doc.node("packages").isNull) return lf;
        foreach (k; doc.keys("packages"))
        {
            auto b = "packages." ~ pathKey(k) ~ ".";
            string g(string f) { return doc.get(b ~ f, null); }
            LockEntry e;
            e.id = k;
            e.version_ = g("version");
            e.range = g("range");
            e.source = g("source");
            e.url = g("url");
            e.ref_ = g("ref");
            e.subdir = g("subdir");
            e.commit = g("commit");
            e.sha256 = g("sha256");
            e.surface = g("surface");
            e.entry = g("entry");
            e.vendored = g("vendored") == "true";
            e.path = g("path");
            e.upstream = g("upstream");
            if (doc.has(b ~ "files") && doc.kind(b ~ "files") == NodeKind.mapping)
                foreach (fk; doc.keys(b ~ "files"))
                    e.files ~= [fk, doc.get(b ~ "files." ~ pathKey(fk), null)];
            lf.packages ~= e;
        }
        return lf;
    }

    /// Deterministic text: packages sorted by ID, fixed key order.
    string emit() const
    {
        auto a = appender!string;
        a.put("# antorareg lockfile. Commit it. Edit by hand or with antorareg; the format is the same.\n");
        a.put("lockfileVersion: " ~ lockfileVersion.to!string ~ "\n");
        a.put("playbook: " ~ yamlScalar(playbook) ~ "\n");
        a.put("antora: " ~ antora.to!string ~ "\n");
        if (packages.length == 0) { a.put("packages: {}\n"); return a.data; }
        a.put("packages:\n");
        auto ps = new const(LockEntry)*[packages.length];
        foreach (i, ref e; packages) ps[i] = &e;
        ps.sort!((x, y) => x.id < y.id);
        foreach (ep; ps)
        {
            const e = *ep;
            a.put("  " ~ yamlScalar(e.id) ~ ":\n");
            void f(string k, string v) { if (v.length) a.put("    " ~ k ~ ": " ~ yamlScalar(v) ~ "\n"); }
            f("version", e.version_);
            f("range", e.range);
            f("source", e.source);
            f("url", e.url);
            f("ref", e.ref_);
            f("subdir", e.subdir);
            f("commit", e.commit);
            f("sha256", e.sha256);
            f("surface", e.surface);
            f("entry", e.entry);
            if (e.vendored) a.put("    vendored: true\n");
            f("path", e.path);
            f("upstream", e.upstream);
            if (e.files.length)
            {
                a.put("    files:\n");
                auto fs = e.files.dup;
                fs.sort!((x, y) => x[0] < y[0]);
                foreach (fl; fs) a.put("      " ~ yamlScalar(fl[0]) ~ ": " ~ fl[1] ~ "\n");
            }
        }
        return a.data;
    }

    LockEntry* find(string id)
    {
        foreach (ref e; packages) if (e.id == id) return &e;
        return null;
    }

    void put(LockEntry e)
    {
        if (auto p = find(e.id)) *p = e; else packages ~= e;
    }

    bool drop(string id)
    {
        auto i = packages.countUntil!(e => e.id == id);
        if (i < 0) return false;
        packages = packages.remove(i);
        return true;
    }
}

unittest // emit then parse is lossless, and emit is stable
{
    Lockfile lf;
    lf.put(LockEntry("github.com/a/b/c", "0.1.0", "^0.1.0", "git", "https://github.com/a/b.git",
        "c-v0.1.0", "packages/c", "4b1e0d7c", "abc123", Surface.extension, "./.antorareg/cache/github.com/a/b/c/lib/index.js"));
    LockEntry v = { id: "github.com/a/t/t", version_: "1.2.0", source: "asset", surface: Surface.bundle,
        url: "https://x.org/ui-bundle.zip", entry: "./ui/t", vendored: true, path: "ui/t", upstream: "1.2.0@deadbeef" };
    v.files = [["lib/index.js", "aa11"], ["README.adoc", "bb22"]];
    lf.put(v);
    auto text = lf.emit();
    auto back = Lockfile.parse(text);
    assert(back.packages.length == 2);
    assert(back.emit() == text, text);
    assert(back.find("github.com/a/b/c").commit == "4b1e0d7c");
    assert(back.find("github.com/a/b/c").version_ == "0.1.0");
    assert(back.find("github.com/a/t/t").vendored);
    assert(back.find("github.com/a/t/t").files.length == 2);
    assert(back.drop("github.com/a/t/t") && back.packages.length == 1);
}

unittest // a hand-written lockfile with comments still parses
{
    auto lf = Lockfile.parse("lockfileVersion: 1\nplaybook: antora-playbook.yml\nantora: 3\npackages:\n"
        ~ "  github.com/x/y/z:   # pinned\n    version: 1.3.0+antora.3\n    source: git\n");
    assert(lf.packages[0].version_ == "1.3.0+antora.3");
    assert(Lockfile.parse("lockfileVersion: 1\npackages: {}\n").packages.length == 0);
}
