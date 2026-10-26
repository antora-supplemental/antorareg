/// Configuration: defaults, user config, `.antorareg.yml`, `ANTORAREG_*` env, then flags (last wins).
module antorareg.config;

import std.file : exists, readText;
import std.path : buildPath, expandTilde;
import std.process : environment;
import yaml_edit;

struct Config
{
    string registry = "https://registry.antora-supplemental.org";
    string source = "git";
    string cacheDir = ".antorareg/cache";
    string vendorDir = "ui";
    string supplementalDir = "./supplemental-ui";

    void merge(string file)
    {
        if (!exists(file)) return;
        auto d = Document.parse(readText(file));
        registry = d.get("registry", registry);
        source = d.get("source", source);
        cacheDir = d.get("cacheDir", cacheDir);
        vendorDir = d.get("vendorDir", vendorDir);
        supplementalDir = d.get("supplementalDir", supplementalDir);
    }

    void mergeEnv()
    {
        registry = environment.get("ANTORAREG_REGISTRY", registry);
        source = environment.get("ANTORAREG_SOURCE", source);
        cacheDir = environment.get("ANTORAREG_CACHE_DIR", cacheDir);
        vendorDir = environment.get("ANTORAREG_VENDOR_DIR", vendorDir);
    }
}

string userConfigFile()
{
    version (Windows) return buildPath(environment.get("APPDATA", "."), "antorareg", "config.yml");
    else return buildPath(environment.get("XDG_CONFIG_HOME", expandTilde("~/.config")), "antorareg", "config.yml");
}

/// Per-user cache root (registry metadata).
string userCacheRoot()
{
    if (auto o = environment.get("ANTORAREG_GLOBAL_CACHE")) return o;
    version (Windows) return buildPath(environment.get("LOCALAPPDATA", "."), "antorareg", "Cache");
    else version (OSX) return expandTilde("~/Library/Caches/antorareg");
    else return buildPath(environment.get("XDG_CACHE_HOME", expandTilde("~/.cache")), "antorareg");
}

Config loadConfig(string projectDir)
{
    Config c;
    c.merge(userConfigFile());
    c.merge(buildPath(projectDir, ".antorareg.yml"));
    c.mergeEnv();
    return c;
}
