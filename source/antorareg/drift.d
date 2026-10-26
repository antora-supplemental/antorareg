/// Drift between the playbook and the lockfile (the lockfile is the only record of ownership).
module antorareg.drift;

import std.algorithm : canFind, startsWith;
import std.file : exists;
import std.path : buildPath;
import antorareg.lockfile;
import antorareg.playbook;

enum DriftKind : string
{
    missing = "missing",         /// lockfile entry whose playbook entry is gone
    handEdited = "hand-edited",  /// playbook entry changed away from the lockfile
    stale = "stale-path",        /// vendored path or cache folder that doesn't exist
}

struct DriftItem
{
    string id;
    DriftKind kind;
    string detail;
}

/// Cache folder of a package, relative to the playbook, '/' separated.
string cacheRel(string cacheDir, string id) { return cacheDir ~ "/" ~ id; }

DriftItem[] detectDrift(ref Playbook pb, const Lockfile lf, string baseDir, string cacheDir, bool checkCache = true)
{
    DriftItem[] r;
    auto reqs = pb.extensionRequires();
    auto bundle = pb.bundleUrl();
    foreach (e; lf.packages)
    {
        if (e.surface == Surface.bundle)
        {
            if (bundle is null)
                r ~= DriftItem(e.id, DriftKind.missing, "ui.bundle.url is not set; lockfile has " ~ e.entry);
            else if (bundle != e.entry)
                r ~= DriftItem(e.id, DriftKind.handEdited, "ui.bundle.url is " ~ bundle ~ "; lockfile has " ~ e.entry);
        }
        else
        {
            if (!reqs.canFind(e.entry))
            {
                auto owned = "./" ~ (e.vendored ? e.path : cacheRel(cacheDir, e.id));
                string other;
                foreach (q; reqs) if (q.length && q.startsWith(owned)) other = q;
                if (other.length)
                    r ~= DriftItem(e.id, DriftKind.handEdited, "antora.extensions requires " ~ other ~ "; lockfile has " ~ e.entry);
                else
                    r ~= DriftItem(e.id, DriftKind.missing, "antora.extensions has no item requiring " ~ e.entry);
            }
        }
        if (e.vendored)
        {
            if (!e.path.length || !exists(buildPath(baseDir, e.path)))
                r ~= DriftItem(e.id, DriftKind.stale, "vendored path " ~ e.path ~ " does not exist");
        }
        else if (checkCache && !exists(buildPath(baseDir, cacheRel(cacheDir, e.id))))
            r ~= DriftItem(e.id, DriftKind.stale, "cache " ~ cacheRel(cacheDir, e.id) ~ " is missing; run antorareg install");
    }
    return r;
}

version (unittest)
{
    private enum string pbText = import("drift-playbook.yml");

    private Lockfile lockFor()
    {
        Lockfile lf;
        lf.put(LockEntry("github.com/o/r/ext", "1.0.0", "^1.0.0", "git", "https://github.com/o/r.git", "ext-v1.0.0",
            null, "c0ffee", "aa", Surface.extension, "./.antorareg/cache/github.com/o/r/ext/lib/index.js"));
        lf.put(LockEntry("github.com/o/t/t", "4.2.2", "^4.2.2", "asset", "https://x.org/ui-bundle.zip", null, null, null,
            "bb", Surface.bundle, "https://x.org/ui-bundle.zip"));
        return lf;
    }
}

unittest // in sync: no drift (cache checks off)
{
    auto pb = Playbook.parse(pbText);
    assert(detectDrift(pb, lockFor(), ".", ".antorareg/cache", false).length == 0);
}

unittest // hand-edited bundle URL and removed extension
{
    import std.array : replace;
    auto pb = Playbook.parse(pbText.replace("https://x.org/ui-bundle.zip", "https://y.org/other.zip")
        .replace("    - require: ./.antorareg/cache/github.com/o/r/ext/lib/index.js\n", ""));
    auto d = detectDrift(pb, lockFor(), ".", ".antorareg/cache", false);
    assert(d.length == 2, d.to!string);
    assert(d.canFind!(x => x.id == "github.com/o/t/t" && x.kind == DriftKind.handEdited));
    assert(d.canFind!(x => x.id == "github.com/o/r/ext" && x.kind == DriftKind.missing));
}

unittest // extension pointed at another file in its own cache folder is hand-edited
{
    import std.array : replace;
    auto pb = Playbook.parse(pbText.replace("ext/lib/index.js", "ext/lib/other.js"));
    auto d = detectDrift(pb, lockFor(), ".", ".antorareg/cache", false);
    assert(d.length == 1 && d[0].kind == DriftKind.handEdited);
}

unittest // stale paths: missing cache and missing vendored copy
{
    auto pb = Playbook.parse(pbText);
    auto lf = lockFor();
    lf.find("github.com/o/t/t").vendored = true;
    lf.find("github.com/o/t/t").path = "ui/does-not-exist";
    auto d = detectDrift(pb, lf, ".", ".antorareg/cache", true);
    assert(d.canFind!(x => x.id == "github.com/o/t/t" && x.kind == DriftKind.stale));
    assert(d.canFind!(x => x.id == "github.com/o/r/ext" && x.kind == DriftKind.stale));
}

unittest // user's own entries are never drift
{
    auto pb = Playbook.parse(pbText);
    Lockfile empty;
    assert(detectDrift(pb, empty, ".", ".antorareg/cache").length == 0);
}

version (unittest) import std.conv : to;
