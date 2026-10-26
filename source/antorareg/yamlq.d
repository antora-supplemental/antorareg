/// Small helpers for writing YAML scalars and quoting path segments.
module antorareg.yamlq;

import std.algorithm : all, canFind;
import std.ascii : isAlphaNum, isDigit;
import std.array : replace;

/// Plain when that is unambiguous, else single-quoted.
string yamlScalar(string v)
{
    static immutable typed = ["", "~", "null", "Null", "NULL", "true", "True", "TRUE", "false", "False",
        "FALSE", "yes", "Yes", "YES", "no", "No", "NO", "on", "On", "ON", "off", "Off", "OFF", "y", "n", "Y", "N"];
    bool plain = !typed.canFind(v)
        && (v[0].isAlphaNum || v[0] == '_' || v[0] == '.' || v[0] == '/' || v[0] == '^')
        && v.all!(c => c.isAlphaNum || "_./:@+^~=-".canFind(c))
        && !v.all!(c => c.isDigit || c == '.' || c == '_' || c == '-' || c == '+')
        && !v.canFind(": ") && v[$ - 1] != ':';
    return plain ? v : "'" ~ v.replace("'", "''") ~ "'";
}

/// Quote a mapping key for a yaml-edit path segment (`packages."a.b/c"`).
string pathKey(string k)
{
    return `"` ~ k.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
}

unittest
{
    assert(yamlScalar("0.1.0") == "'0.1.0'");
    assert(yamlScalar("1.3.0+antora.3") == "1.3.0+antora.3");
    assert(yamlScalar("^1.2.0") == "^1.2.0");
    assert(yamlScalar("https://x.org/a.zip") == "https://x.org/a.zip");
    assert(yamlScalar("true") == "'true'");
    assert(yamlScalar("@antora/lunr") == "'@antora/lunr'");
    assert(yamlScalar("it's") == "'it''s'");
    assert(yamlScalar(">=1.0.0") == "'>=1.0.0'");
}
