/**
 * Tests for wikiLink extension — renderHTML output and edge cases.
 * Extends coverage beyond markdownArtifacts.test.ts which covers parseHTML/getAttrs.
 */

import { describe, it, expect } from "vitest";
import { wikiLinkExtension } from "../wikiLink";

describe("wikiLinkExtension", () => {
  describe("extension config", () => {
    it("has name wikiLink", () => {
      expect(wikiLinkExtension.name).toBe("wikiLink");
    });

    it("is selectable", () => {
      expect(wikiLinkExtension.config.selectable).toBe(true);
    });

    it("is inline", () => {
      expect(wikiLinkExtension.config.inline).toBe(true);
    });

    it("belongs to inline group", () => {
      expect(wikiLinkExtension.config.group).toBe("inline");
    });

    it("has text* content", () => {
      expect(wikiLinkExtension.config.content).toBe("text*");
    });

    it("is NOT an atom node (has content hole)", () => {
      expect(wikiLinkExtension.config.atom).toBeUndefined();
    });
  });

  describe("addAttributes", () => {
    const attrs = wikiLinkExtension.config.addAttributes!.call({} as never)!;

    it("has value attribute with empty string default", () => {
      expect(attrs.value).toBeDefined();
      expect(attrs.value.default).toBe("");
    });

    it("has sourceLine attribute", () => {
      expect(attrs.sourceLine).toBeDefined();
      expect(attrs.sourceLine.default).toBeNull();
    });
  });

  describe("renderHTML", () => {
    const renderHTML = wikiLinkExtension.config.renderHTML!;

    it("renders span with data-type wiki-link and content hole", () => {
      const node = { attrs: { value: "target-page" } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect(result).toEqual([
        "span",
        expect.objectContaining({
          "data-type": "wiki-link",
          "data-value": "target-page",
          class: "wiki-link",
        }),
        0, // content hole
      ]);
    });

    it("renders 0 as third element (content hole for text)", () => {
      const node = { attrs: { value: "page" } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect(result[2]).toBe(0);
    });

    it("handles null value gracefully", () => {
      const node = { attrs: { value: null } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect((result[1] as Record<string, string>)["data-value"]).toBe("");
    });

    it("handles undefined value gracefully", () => {
      const node = { attrs: { value: undefined } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect((result[1] as Record<string, string>)["data-value"]).toBe("");
    });

    it("merges additional HTML attributes", () => {
      const node = { attrs: { value: "page" } } as never;
      const result = renderHTML.call({} as never, {
        node,
        HTMLAttributes: { id: "link-1" },
      });
      const attrs = result[1] as Record<string, string>;
      expect(attrs.id).toBe("link-1");
      expect(attrs.class).toBe("wiki-link");
    });

    it("handles path-like values", () => {
      const node = { attrs: { value: "folder/sub-folder/page" } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect((result[1] as Record<string, string>)["data-value"]).toBe("folder/sub-folder/page");
    });

    it("handles values with special characters", () => {
      const node = { attrs: { value: "page with spaces & symbols (1)" } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect((result[1] as Record<string, string>)["data-value"]).toBe(
        "page with spaces & symbols (1)"
      );
    });

    it("handles CJK characters in value", () => {
      const node = { attrs: { value: "CJK" } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect((result[1] as Record<string, string>)["data-value"]).toBe("CJK");
    });

    it("handles empty string value", () => {
      const node = { attrs: { value: "" } } as never;
      const result = renderHTML.call({} as never, { node, HTMLAttributes: {} });
      expect((result[1] as Record<string, string>)["data-value"]).toBe("");
    });
  });

  describe("parseHTML edge cases", () => {
    const parseRules = wikiLinkExtension.config.parseHTML!.call({} as never)!;
    const rule = parseRules[0];

    it("matches correct tag selector", () => {
      expect(rule.tag).toBe('span[data-type="wiki-link"]');
    });

    const getAttrs = rule.getAttrs as (el: HTMLElement) => Record<string, unknown> | false;

    it("trims textContent in fallback", () => {
      const el = document.createElement("span");
      el.setAttribute("data-type", "wiki-link");
      el.textContent = "  target page  ";
      // textContent?.trim() is used
      expect(getAttrs(el)).toEqual({ value: "target page" });
    });

    it("returns false for whitespace-only textContent", () => {
      const el = document.createElement("span");
      el.setAttribute("data-type", "wiki-link");
      el.textContent = "   ";
      // "   ".trim() === "" which is falsy
      expect(getAttrs(el)).toBe(false);
    });

    it("prefers data-value over textContent when data-value is truthy", () => {
      const el = document.createElement("span");
      el.setAttribute("data-type", "wiki-link");
      el.setAttribute("data-value", "from-attr");
      el.textContent = "from-text";
      expect(getAttrs(el)).toEqual({ value: "from-attr" });
    });

    it("falls through to textContent when data-value is empty", () => {
      const el = document.createElement("span");
      el.setAttribute("data-type", "wiki-link");
      el.setAttribute("data-value", "");
      el.textContent = "fallback-text";
      // "" is falsy, so falls through to textContent
      expect(getAttrs(el)).toEqual({ value: "fallback-text" });
    });

    it("handles null textContent", () => {
      const el = document.createElement("span");
      el.setAttribute("data-type", "wiki-link");
      // textContent is "" by default for empty element
      expect(getAttrs(el)).toBe(false);
    });
  });
});
