/**
Playbook editing on top of yaml-edit. Only `ui.bundle.url`, `ui.bundle.snapshot`,
`antora.extensions` and `ui.supplemental_files` are touched; every other byte is
kept. When a target can't be edited safely the edit stops with `ManualEdit`,
which carries the exact change for the user to make by hand.
*/
module antorareg.playbook;

import std.algorithm : canFind, min;
import std.array : appender;
import std.conv : to;
import std.file : exists, readText, rename, write;
import std.path : dirName;
import std.string : splitLines;
import yaml_edit;

/// The edit can't be made safely; `instructions` says what to change by hand.
class ManualEdit : Exception
{
    string instructions;
    this(string reason, string instructions)
    {
        super(reason);
        this.instructions = instructions;
    }
}

struct Playbook
{
    string path;
    string original;
    Document doc;

    static Playbook load(string path)
    {
        return parse(readText(path), path);
    }

    static Playbook parse(string text, string path = "antora-playbook.yml")
    {
        Playbook p;
        p.path = path;
        p.original = text;
        try p.doc = Document.parse(text);
        catch (YamlEditException e)
            throw new ManualEdit("the playbook can't be edited safely: " ~ e.msg,
                "Fix or simplify the playbook (one YAML document, block style), or make the change by hand.");
        return p;
    }

    string emit() { return doc.emit(); }
    bool changed() { return doc.emit() != original; }

    /// Write atomically (temp file, then rename). UTF-8 bytes as emitted; line endings are the file's own.
    void save()
    {
        auto tmp = path ~ ".antorareg-tmp";
        write(tmp, emit());
        rename(tmp, path);
        original = emit();
    }

    // ------------------------------------------------------------ reads

    private bool readable(string p)
    {
        try return doc.has(p) && doc.kind(p) != NodeKind.opaque;
        catch (YamlEditException) return false;
    }

    /// `ui.bundle.url`, or null.
    string bundleUrl()
    {
        if (!readable("ui.bundle.url")) return null;
        try return doc.get("ui.bundle.url", null);
        catch (YamlEditException) return null;
    }

    /// The require value of each `antora.extensions` item (null for unreadable items).
    string[] extensionRequires()
    {
        string[] r;
        if (!readable("antora.extensions") || doc.kind("antora.extensions") != NodeKind.sequence) return r;
        foreach (i; 0 .. doc.length("antora.extensions"))
        {
            auto p = "antora.extensions[" ~ i.to!string ~ "]";
            string v;
            try
            {
                auto k = doc.kind(p);
                if (k == NodeKind.scalar) v = doc.get(p);
                else if (k == NodeKind.mapping && doc.has(p ~ ".require")) v = doc.get(p ~ ".require", null);
            }
            catch (YamlEditException) {}
            r ~= v;
        }
        return r;
    }

    /// `ui.supplemental_files` when it is a path, or null.
    string supplementalPath()
    {
        if (!readable("ui.supplemental_files") || doc.kind("ui.supplemental_files") != NodeKind.scalar) return null;
        return doc.get("ui.supplemental_files", null);
    }


    private bool safeHas(string p)
    {
        try return doc.has(p);
        catch (YamlEditException) return true; // opaque parent: treat as present, never overwrite
    }

    // ------------------------------------------------------------ edits

    private void guard(string target, string manual)
    {
        foreach (p; parents(target))
        {
            bool h;
            try h = doc.has(p);
            catch (YamlEditException e) throw new ManualEdit("`" ~ p ~ "` can't be edited safely: " ~ e.msg, manual);
            if (h && doc.kind(p) == NodeKind.opaque)
                throw new ManualEdit("`" ~ p ~ "` uses a flow collection, anchor, alias or tag", manual);
        }
    }

    private static string[] parents(string target)
    {
        string[] r;
        foreach (i, c; target) if (c == '.') r ~= target[0 .. i];
        r ~= target;
        return r;
    }

    private void attempt(string manual, scope void delegate() edit)
    {
        auto before = doc.emit();
        try edit();
        catch (YamlEditException e)
        {
            doc = Document.parse(before);
            throw new ManualEdit("the playbook can't be edited safely: " ~ e.msg, manual);
        }
    }

    /// Set the UI bundle URL (and `snapshot` when given).
    void setBundle(string url, string snapshot = null)
    {
        auto manual = "Set this in " ~ path ~ ":\n\nui:\n  bundle:\n    url: " ~ url
            ~ (snapshot.length ? "\n    snapshot: " ~ snapshot : "") ~ "\n";
        guard("ui.bundle.url", manual);
        attempt(manual, {
            doc.set("ui.bundle.url", url);
            if (snapshot.length) doc.set("ui.bundle.snapshot", snapshot, ScalarStyle.plain);
        });
    }

    /// Index of the extension item whose value or `require` equals `value`, or -1.
    long findExtension(string value)
    {
        foreach (i, r; extensionRequires()) if (r == value) return cast(long) i;
        return -1;
    }

    /// Append `- require: value` unless it is already there.
    void addExtension(string value)
    {
        if (findExtension(value) >= 0) return;
        auto manual = "Add this item to antora.extensions in " ~ path ~ ":\n\nantora:\n  extensions:\n    - require: "
            ~ value ~ "\n";
        guard("antora.extensions", manual);
        attempt(manual, { doc.appendItem("antora.extensions", [["require", value]]); });
    }

    /// Replace the item that requires `oldValue` with `newValue`, in place. Appends when the old one is gone.
    void replaceExtension(string oldValue, string newValue)
    {
        auto i = findExtension(oldValue);
        if (i < 0) { addExtension(newValue); return; }
        auto p = "antora.extensions[" ~ i.to!string ~ "]";
        auto manual = "In antora.extensions of " ~ path ~ ", change\n\n    " ~ oldValue ~ "\n\nto\n\n    " ~ newValue ~ "\n";
        guard("antora.extensions", manual);
        attempt(manual, {
            if (doc.kind(p) == NodeKind.scalar) doc.set(p, newValue);
            else doc.set(p ~ ".require", newValue);
        });
    }

    /// Remove the item that requires `value`. Returns false when it isn't there.
    bool removeExtension(string value)
    {
        auto i = findExtension(value);
        if (i < 0) return false;
        auto manual = "Remove this item from antora.extensions in " ~ path ~ ":\n\n    - require: " ~ value ~ "\n";
        guard("antora.extensions", manual);
        attempt(manual, { doc.removeItem("antora.extensions", cast(size_t) i); });
        return true;
    }

    /// Set `ui.supplemental_files` to `dir` when the key is absent. Returns the folder in use (null for a list).
    string ensureSupplemental(string dir)
    {
        if (safeHas("ui.supplemental_files")) return supplementalPath();
        auto manual = "Add this to " ~ path ~ ":\n\nui:\n  supplemental_files: " ~ dir ~ "\n";
        guard("ui.supplemental_files", manual);
        attempt(manual, { doc.set("ui.supplemental_files", dir); });
        return dir;
    }
}

/// A minimal unified diff of the one changed region (edits are local, so one hunk is enough).
string unifiedDiff(string a, string b, string name)
{
    auto x = a.splitLines, y = b.splitLines;
    if (a == b) return "";
    size_t pre;
    while (pre < x.length && pre < y.length && x[pre] == y[pre]) pre++;
    size_t suf;
    while (suf < x.length - pre && suf < y.length - pre && x[$ - 1 - suf] == y[$ - 1 - suf]) suf++;
    auto ctx0 = pre >= 3 ? pre - 3 : 0;
    auto endX = x.length - suf, endY = y.length - suf;
    auto ctx1 = min(x.length, endX + 3);
    auto o = appender!string;
    o.put("--- a/" ~ name ~ "\n+++ b/" ~ name ~ "\n");
    o.put("@@ -" ~ (ctx0 + 1).to!string ~ "," ~ (ctx1 - ctx0).to!string ~ " +" ~ (ctx0 + 1).to!string ~ ","
        ~ (ctx1 - ctx0 + endY - endX).to!string ~ " @@\n");
    foreach (l; x[ctx0 .. pre]) o.put(" " ~ l ~ "\n");
    foreach (l; x[pre .. endX]) o.put("-" ~ l ~ "\n");
    foreach (l; y[pre .. endY]) o.put("+" ~ l ~ "\n");
    foreach (l; x[endX .. ctx1]) o.put(" " ~ l ~ "\n");
    return o.data;
}
