/**
Registry client. Reads the catalog from `<registry>/api/extensions/catalog`
(schema 1.0) and resolves package IDs, search terms and version ranges.
*/
module antorareg.registry;

import std.algorithm : canFind, filter, sort, startsWith, endsWith;
import std.array : array;
import std.conv : to;
import std.datetime : Clock, dur;
import std.exception : enforce;
import std.file;
import std.json;
import std.path : buildPath, dirName;
import std.string : toLower, replace, indexOf;
import antorareg.fetch : download;
import antorareg.pkgid;
import antorareg.semver;

struct Asset { string name, url, digest; }

struct Release
{
    string tag;
    SemVer ver;
    bool prerelease;
    int[] antora;
    Asset[] assets;

    bool hasBundle() const { return assets.canFind!(a => a.name == "ui-bundle.zip"); }
}

struct Module
{
    string catalogId, id, name, type, repository, modulePath, host;
    string[] blockedVersions;
    Release[] releases;

    PackageId pid() const
    {
        auto p = catalogId.split3;
        return PackageId(host, p[0], p[1], p[2]);
    }

    string gitUrl() const { return repository.endsWith(".git") ? repository : repository ~ ".git"; }
}

private string[3] split3(string s)
{
    import std.string : split;
    auto p = s.split("/");
    enforce(p.length == 3, "bad catalogId " ~ s);
    return [p[0], p[1], p[2]];
}

/// Exit code 2 per the spec: ambiguous or unknown name.
class ResolveError : Exception
{
    int code;
    this(string m, int code = 2) { super(m); this.code = code; }
}

private string s(JSONValue v, string k)
{
    if (v.type != JSONType.object) return null;
    auto p = k in v.object;
    return p && p.type == JSONType.string ? p.str : null;
}

Module[] parseCatalog(string text)
{
    auto j = parseJSON(text);
    Module[] r;
    auto mods = "modules" in j.object;
    if (!mods) return r;
    foreach (m; mods.array)
    {
        Module x;
        x.catalogId = s(m, "catalogId");
        x.id = s(m, "id");
        x.name = s(m, "name");
        x.type = s(m, "type");
        x.repository = s(m, "repository");
        x.modulePath = s(m, "modulePath");
        x.host = "github.com";
        if (x.repository.length)
        {
            auto u = x.repository.replace("https://", "");
            auto sl = u.indexOf('/');
            if (sl > 0) x.host = u[0 .. sl];
        }
        if (auto o = "owner" in m.object) if (s(*o, "host").length) x.host = s(*o, "host");
        if (auto rs = "releases" in m.object)
            if (rs.type == JSONType.array)
                foreach (rel; rs.array)
                {
                    Release y;
                    y.tag = s(rel, "tag");
                    auto label = s(rel, "label");
                    if (!SemVer.tryParse(label.length ? label : s(rel, "version"), y.ver)) continue;
                    if (auto p = "prerelease" in rel.object) y.prerelease = p.type == JSONType.true_;
                    if (auto a = "antora" in rel.object)
                        if (a.type == JSONType.array) foreach (n; a.array) if (n.type == JSONType.integer) y.antora ~= cast(int) n.integer;
                    if (auto a = "assets" in rel.object)
                        if (a.type == JSONType.array) foreach (as; a.array) y.assets ~= Asset(s(as, "name"), s(as, "url"), s(as, "digest"));
                    x.releases ~= y;
                }
        if (auto b = "securityBlocked" in m.object)
            if (b.type == JSONType.array) foreach (v; b.array) if (v.type == JSONType.string) x.blockedVersions ~= v.str;
        if (x.catalogId.length) r ~= x;
    }
    return r;
}

/// Find one module by full ID, short ID or a unique search term.
Module resolve(Module[] mods, string query)
{
    PackageId id;
    if (parseId(query, id))
    {
        foreach (m; mods) if (m.catalogId == id.catalogId && m.host == id.host) return m;
        throw new ResolveError("no registry package " ~ id.toString);
    }
    auto q = query.toLower;
    auto hits = mods.filter!(m => m.id.toLower == q || m.name.toLower == q || m.catalogId.endsWith("/" ~ q)).array;
    if (hits.length == 0) hits = mods.filter!(m => m.id.toLower.canFind(q) || m.name.toLower.canFind(q)).array;
    if (hits.length == 1) return hits[0];
    import std.algorithm : map;
    import std.array : join;
    if (hits.length == 0) throw new ResolveError("no registry package matches '" ~ query ~ "'");
    throw new ResolveError("'" ~ query ~ "' matches several packages; use a full ID:\n  "
        ~ hits.map!(m => m.pid.toString).join("\n  "));
}

/**
Newest release in `range` for Antora `antoraMajor`. Releases whose build
metadata names another Antora line are skipped; releases without `+antora`
count when the registry lists `antoraMajor` (or lists nothing).
*/
Release pick(Module m, string range, int antoraMajor)
{
    Release[] ok;
    foreach (r; m.releases)
    {
        auto t = r.ver.antoraTarget;
        if (t && t != antoraMajor) continue;
        if (!t && r.antora.length && !r.antora.canFind(antoraMajor)) continue;
        if (r.prerelease && !range.canFind('-')) continue;
        if (!satisfies(r.ver, range)) continue;
        if (m.blockedVersions.canFind(r.ver.toString) || m.blockedVersions.canFind(r.tag)) continue;
        ok ~= r;
    }
    if (!ok.length)
        throw new ResolveError("no release of " ~ m.pid.toString ~ " matches '" ~ range ~ "' for Antora "
            ~ antoraMajor.to!string, 1);
    ok.sort!((a, b) => a.ver > b.ver);
    return ok[0];
}

/// Catalog text from the per-user cache (24 h soft TTL) or the network.
string loadCatalogText(string registry, string cacheRoot, bool offline)
{
    auto file = buildPath(cacheRoot, "registry", "catalog.json");
    bool fresh = exists(file) && Clock.currTime - timeLastModified(file) < dur!"hours"(24);
    if (offline)
    {
        enforce(exists(file), "--offline: no cached registry catalog at " ~ file);
        return readText(file);
    }
    if (!fresh)
    {
        auto tmp = file ~ ".tmp";
        download(registry ~ "/api/extensions/catalog?topics=false", tmp);
        rename(tmp, file);
    }
    return readText(file);
}

unittest
{
    enum cat = `{"schema":"1.0","modules":[
      {"catalogId":"antora-supplemental/antora-ui-chassis/asset-fingerprint","id":"asset-fingerprint",
       "name":"Asset Fingerprint","type":"ui-module","repository":"https://github.com/antora-supplemental/antora-ui-chassis",
       "modulePath":"packages/asset-fingerprint","releases":[
         {"tag":"asset-fingerprint-v0.1.0","version":"0.1.0","label":"0.1.0+antora.3","antora":[3],"assets":[]},
         {"tag":"asset-fingerprint-v0.2.0","version":"0.2.0","label":"0.2.0+antora.4","antora":[4],"assets":[]},
         {"tag":"asset-fingerprint-v0.1.1","version":"0.1.1","antora":[3],"prerelease":false,"assets":[]}]},
      {"catalogId":"antora-supplemental/valentus-theme/vcs-icons","id":"vcs-icons","name":"VCS icons",
       "repository":"https://github.com/antora-supplemental/valentus-theme","releases":[
         {"tag":"v4.2.2","version":"4.2.2","antora":[3],"assets":[{"name":"ui-bundle.zip","url":"https://x/ui-bundle.zip"}]}]},
      {"catalogId":"antora-supplemental/valentus-theme/vcs-links","id":"vcs-links","name":"VCS links","releases":[]}]}`;
    auto mods = parseCatalog(cat);
    assert(mods.length == 3);
    auto m = resolve(mods, "github.com/antora-supplemental/antora-ui-chassis/asset-fingerprint");
    assert(m.pid.toString == "github.com/antora-supplemental/antora-ui-chassis/asset-fingerprint");
    assert(resolve(mods, "Asset Fingerprint").id == "asset-fingerprint");
    assert(pick(m, "", 3).tag == "asset-fingerprint-v0.1.1");
    assert(pick(m, "", 4).tag == "asset-fingerprint-v0.2.0");
    assert(pick(m, "~0.1.0", 3).ver.patch == 1);
    assert(resolve(mods, "vcs-icons").releases[0].hasBundle);
    bool amb;
    try resolve(mods, "vcs"); catch (ResolveError e) amb = e.code == 2;
    assert(amb);
}
