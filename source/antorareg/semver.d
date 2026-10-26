/// Minimal SemVer 2.0 parsing, ordering and npm-style ranges (^, ~, exact, >=).
module antorareg.semver;

import std.algorithm : all, startsWith;
import std.ascii : isDigit;
import std.conv : to;
import std.string : indexOf, split, strip;

struct SemVer
{
    int major, minor, patch;
    string pre;   /// prerelease, without '-'
    string build; /// build metadata, without '+'

    /// Parse `1.2.3`, `v1.2.3-rc.1+antora.3`. Returns false when not SemVer.
    static bool tryParse(string s, out SemVer v)
    {
        s = s.strip;
        if (s.startsWith("v")) s = s[1 .. $];
        auto plus = s.indexOf('+');
        if (plus >= 0) { v.build = s[plus + 1 .. $]; s = s[0 .. plus]; }
        auto dash = s.indexOf('-');
        if (dash >= 0) { v.pre = s[dash + 1 .. $]; s = s[0 .. dash]; }
        auto parts = s.split('.');
        if (parts.length != 3) return false;
        foreach (p; parts) if (p.length == 0 || !p.all!isDigit) return false;
        v.major = parts[0].to!int; v.minor = parts[1].to!int; v.patch = parts[2].to!int;
        return true;
    }

    static SemVer parse(string s)
    {
        SemVer v;
        if (!tryParse(s, v)) throw new Exception("not a SemVer version: " ~ s);
        return v;
    }

    /// Precedence; build metadata is ignored as SemVer requires.
    int opCmp(const SemVer o) const
    {
        if (major != o.major) return major < o.major ? -1 : 1;
        if (minor != o.minor) return minor < o.minor ? -1 : 1;
        if (patch != o.patch) return patch < o.patch ? -1 : 1;
        if (pre == o.pre) return 0;
        if (pre.length == 0) return 1;
        if (o.pre.length == 0) return -1;
        return pre < o.pre ? -1 : 1;
    }

    bool opEquals(const SemVer o) const { return opCmp(o) == 0; }

    string toString() const
    {
        auto s = major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
        if (pre.length) s ~= "-" ~ pre;
        if (build.length) s ~= "+" ~ build;
        return s;
    }

    /// Antora major named in build metadata (`+antora.3`), or 0.
    int antoraTarget() const
    {
        auto i = build.indexOf("antora.");
        if (i < 0) return 0;
        auto rest = build[i + 7 .. $];
        size_t n;
        while (n < rest.length && rest[n].isDigit) n++;
        return n ? rest[0 .. n].to!int : 0;
    }
}

/// True when `v` satisfies `range`: empty, `*`, `latest`, `x.y.z`, `^x.y.z`, `~x.y.z`, `>=x.y.z`.
bool satisfies(SemVer v, string range)
{
    range = range.strip;
    if (range.length == 0 || range == "*" || range == "latest") return v.pre.length == 0;
    if (range.startsWith(">="))
        return v >= SemVer.parse(range[2 .. $]);
    if (range.startsWith("^"))
    {
        auto b = SemVer.parse(range[1 .. $]);
        if (v < b) return false;
        if (b.major > 0) return v.major == b.major;
        if (b.minor > 0) return v.major == 0 && v.minor == b.minor;
        return v.major == 0 && v.minor == 0 && v.patch == b.patch;
    }
    if (range.startsWith("~"))
    {
        auto b = SemVer.parse(range[1 .. $]);
        return v >= b && v.major == b.major && v.minor == b.minor;
    }
    return v == SemVer.parse(range);
}

unittest
{
    auto v = SemVer.parse("v1.3.0+antora.3");
    assert(v.major == 1 && v.minor == 3 && v.antoraTarget == 3);
    assert(SemVer.parse("1.0.0") > SemVer.parse("1.0.0-rc.1"));
    assert(SemVer.parse("1.2.0+antora.3") == SemVer.parse("1.2.0+antora.4"));
    assert(satisfies(SemVer.parse("1.4.0"), "^1.2.0"));
    assert(!satisfies(SemVer.parse("2.0.0"), "^1.2.0"));
    assert(satisfies(SemVer.parse("0.1.5"), "^0.1.0"));
    assert(!satisfies(SemVer.parse("0.2.0"), "^0.1.0"));
    assert(satisfies(SemVer.parse("1.2.9"), "~1.2.0"));
    assert(!satisfies(SemVer.parse("1.3.0"), "~1.2.0"));
    assert(satisfies(SemVer.parse("1.2.0"), "1.2.0"));
    assert(satisfies(SemVer.parse("3.0.0"), ">=1.0.0"));
    assert(!satisfies(SemVer.parse("1.0.0-rc.1"), ""));
    SemVer x;
    assert(!SemVer.tryParse("1.2", x));
}
