/**
 * TOC block click → scroll (#1458).
 *
 * A TOC link must scroll the editor's scroll container so its heading lands
 * at the top, through settledScroll — on large documents content-visibility
 * moves the heading while a smooth scroll is in flight. Real-engine proof of
 * the settling is utils/settledScroll.webkit.test.ts.
 */
import { describe, it, expect, vi, afterEach } from "vitest";
import { Schema } from "@tiptap/pm/model";
import type { EditorView } from "@tiptap/pm/view";
import { createTocNodeView } from "../TocNodeView";
import { scrollBehavior } from "@/utils/motion";

const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "text*" },
    heading: { group: "block", content: "text*", attrs: { level: { default: 1 } } },
    toc: { group: "block", atom: true },
    text: {},
  },
});

function rectAt(top: number): DOMRect {
  return { top, bottom: top + 20, left: 0, right: 0, width: 0, height: 20, x: 0, y: top, toJSON: () => ({}) };
}

function mountToc(scrollerTop: number, headingTop: number) {
  const doc = schema.node("doc", null, [
    schema.node("toc"),
    schema.node("paragraph", null, [schema.text("intro")]),
    schema.node("heading", { level: 2 }, [schema.text("Far away")]),
  ]);
  const scroller = document.createElement("div");
  scroller.className = "editor-content";
  scroller.scrollTo = vi.fn();
  scroller.getBoundingClientRect = () => rectAt(scrollerTop);
  const pm = document.createElement("div");
  const heading = document.createElement("h2");
  heading.getBoundingClientRect = () => rectAt(headingTop);
  pm.appendChild(heading);
  scroller.appendChild(pm);
  document.body.appendChild(scroller);

  const view = {
    dom: pm,
    state: { doc, tr: { setSelection: vi.fn().mockReturnThis() } },
    dispatch: vi.fn(),
    focus: vi.fn(),
    domAtPos: vi.fn(() => ({ node: heading, offset: 0 })),
  } as unknown as EditorView;

  const nodeView = createTocNodeView(doc.child(0), view, () => 0);
  pm.prepend(nodeView.dom!);
  return { scroller, nodeView };
}

describe("TOC block click", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("scrolls the editor's scroll container so the heading reaches its top", () => {
    const { scroller, nodeView } = mountToc(100, 1300);
    const link = (nodeView.dom as HTMLElement).querySelector("a[data-toc-pos]") as HTMLAnchorElement;

    link.click();

    expect(scroller.scrollTo).toHaveBeenCalledWith({ top: 1200, behavior: scrollBehavior() });
  });
});
