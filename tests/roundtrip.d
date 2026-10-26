/// Byte-for-byte playbook round-trips, minimal edits, and manual-edit refusals.
module roundtrip;

import std.algorithm : canFind;
import std.array : replace;
import antorareg.playbook;

private enum lf = import("rt-lf.yml");
private enum crlf = import("rt-crlf.yml");

unittest // untouched documents emit identical bytes (LF and CRLF)
{
    foreach (t; [lf, crlf])
    {
        auto pb = Playbook.parse(t);
        assert(pb.emit() == t);
        assert(!pb.changed);
    }
    assert(crlf.canFind("\r\n"));
}

unittest // add an extension: only that line changes, line endings kept
{
    foreach (t; [lf, crlf])
    {
        auto nl = t.canFind("\r\n") ? "\r\n" : "\n";
        auto pb = Playbook.parse(t);
        pb.addExtension("./.antorareg/cache/github.com/o/r/p/lib/index.js");
        auto o = pb.emit();
        assert(o.canFind("- require: ./.antorareg/cache/github.com/o/r/p/lib/index.js" ~ nl), o);
        // removing it again restores the original bytes
        auto back = Playbook.parse(o);
        assert(back.removeExtension("./.antorareg/cache/github.com/o/r/p/lib/index.js"));
        assert(back.emit() == t, back.emit());
        // the flow map in a sibling item is untouched
        assert(o.canFind("config: {a: 1, list: [x, y]}"));
        assert(o.canFind("title: Example Docs   # trailing comment"));
    }
}

unittest // set the bundle URL in place, keeping other keys and comments
{
    auto pb = Playbook.parse(lf);
    pb.setBundle("https://github.com/o/r/releases/download/v1/ui-bundle.zip");
    auto o = pb.emit();
    assert(o == lf.replace("https://example.org/ui-bundle.zip", "https://github.com/o/r/releases/download/v1/ui-bundle.zip"), o);
}

private void expectManual(string text, void delegate(ref Playbook) edit)
{
    bool threw;
    try
    {
        auto pb = Playbook.parse(text);
        edit(pb);
    }
    catch (ManualEdit m) { threw = true; assert(m.instructions.length); }
    assert(threw);
}

unittest // flow lists, anchors and multi-document files: print the manual change and stop
{
    expectManual(import("manual-flow.yml"), (ref Playbook p) => p.addExtension("./x.js"));
    expectManual(import("manual-anchor.yml"), (ref Playbook p) => p.addExtension("./x.js"));
    expectManual(import("manual-anchor.yml"), (ref Playbook p) => p.setBundle("https://y/ui-bundle.zip"));
    expectManual(import("manual-multi.yml"), (ref Playbook p) => p.addExtension("./x.js"));
}
