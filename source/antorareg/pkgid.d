/// Package identity: `<host>/<owner>/<repo>/<package>`.
module antorareg.pkgid;

import std.algorithm : canFind;
import std.string : indexOf, split;

struct PackageId
{
    string host, owner, repo, pkg;

    string toString() const { return host ~ "/" ~ owner ~ "/" ~ repo ~ "/" ~ pkg; }

    /// Registry catalogId (`owner/repo/package`).
    string catalogId() const { return owner ~ "/" ~ repo ~ "/" ~ pkg; }
}

/**
Parse a package ID. Accepts the four-segment form, the three-segment short
form `host/owner/repo` (package = repo) and the registry catalogId form
`owner/repo/package` (host github.com). Returns false for a bare search term.
*/
bool parseId(string s, out PackageId id)
{
    auto at = s.indexOf('@');
    if (at > 0) s = s[0 .. at];
    auto p = s.split('/');
    foreach (seg; p) if (seg.length == 0) return false;
    if (p.length == 4) { id = PackageId(p[0], p[1], p[2], p[3]); return true; }
    if (p.length == 3)
    {
        if (p[0].canFind('.')) id = PackageId(p[0], p[1], p[2], p[2]);
        else id = PackageId("github.com", p[0], p[1], p[2]);
        return true;
    }
    return false;
}

/// Split `id@range` into the ID text and range (range may be empty).
void splitRange(string arg, out string name, out string range)
{
    auto at = arg.indexOf('@', 1); // a leading '@' belongs to an npm scope
    if (at > 0) { name = arg[0 .. at]; range = arg[at + 1 .. $]; }
    else { name = arg; range = null; }
}

unittest
{
    PackageId id;
    assert(parseId("github.com/antora-supplemental/antora-dark-mode/antora-dark-mode", id));
    assert(id.pkg == "antora-dark-mode" && id.host == "github.com");
    assert(parseId("gitlab.com/acme/docs-tools", id) && id.pkg == "docs-tools" && id.host == "gitlab.com");
    assert(parseId("antora-supplemental/antora-ui-chassis/asset-fingerprint", id));
    assert(id.toString == "github.com/antora-supplemental/antora-ui-chassis/asset-fingerprint");
    assert(!parseId("dark-mode", id));
    string n, r;
    splitRange("a/b/c@^1.2.0", n, r);
    assert(n == "a/b/c" && r == "^1.2.0");
    splitRange("dark-mode", n, r);
    assert(n == "dark-mode" && r is null);
}
