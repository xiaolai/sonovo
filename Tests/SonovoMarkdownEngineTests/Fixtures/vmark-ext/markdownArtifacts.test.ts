/**
 * Tests for markdownArtifacts extensions — frontmatter, htmlInline, htmlBlock,
 * linkDefinition, wikiLink.
 *
 * Focus: extension metadata, parseHTML getAttrs logic, renderHTML output.
 */

import { describe, it, expect } from "vitest";
import { frontmatterExtension } from "../frontmatter";
import { htmlInlineExtension } from "../htmlInline";
import { htmlBlockExtension } from "../htmlBlock";
import { linkDefinitionExtension } from "../linkDefinition";
import { wikiLinkExtension } from "../wikiLink";

// ---------------------------------------------------------------------------
// Helpers — simulate DOM elements for parseHTML getAttrs
// ---------------------------------------------------------------------------

function makeElement(tag: string, attrs: Record<string, string> = {}, textContent = ""): HTMLElement {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  if (textContent) el.textContent = textContent;
  return el;
}

// ---------------------------------------------------------------------------
// frontmatter
// ---------------------------------------------------------------------------

describe("frontmatterExtension", () => {
  it("has correct name", () => {
    expect(frontmatterExtension.name).toBe("frontmatter");
  });

  it("is an atom node", () => {
    expect(frontmatterExtension.config.atom).toBe(true);
    expect(frontmatterExtension.config.selectable).toBe(false);
    expect(frontmatterExtension.config.isolating).toBe(true);
  });

  describe("parseHTML getAttrs", () => {
    const parseRules = frontmatterExtension.config.parseHTML!.call({} as never)!;
    const getAttrs = parseRules[0].getAttrs as (el: HTMLElement) => Record<string, unknown> | false;

    it("extracts value from data-value attribute", () => {
      const el = makeElement("div", { "data-type": "frontmatter", "data-value": "title: hello" });
      expect(getAttrs(el)).toEqual({ value: "title: hello" });
    });

    it("falls back to textContent when data-value is absent", () => {
      const el = makeElement("div", { "data-type": "frontmatter" }, "title: fallback");
      expect(getAttrs(el)).toEqual({ value: "title: fallback" });
    });

    it("returns false when both data-value and textContent are empty", () => {
      const el = makeElement("div", { "data-type": "frontmatter" });
      expect(getAttrs(el)).toBe(false);
    });

    it("returns data-value even if empty string (attribute exists)", () => {
      const el = makeElement("div", { "data-type": "frontmatter", "data-value": "" });
      expect(getAttrs(el)).toEqual({ value: "" });
    });

    it("trims textContent fallback", () => {
      const el = makeElement("div", { "data-type": "frontmatter" }, "  title: trimmed  ");
      expect(getAttrs(el)).toEqual({ value: "title: trimmed" });
    });
  });
});

// ---------------------------------------------------------------------------
// htmlInline
// ---------------------------------------------------------------------------

describe("htmlInlineExtension", () => {
  it("has correct name", () => {
    expect(htmlInlineExtension.name).toBe("html_inline");
  });

  it("is inline and atom", () => {
    expect(htmlInlineExtension.config.atom).toBe(true);
    expect(htmlInlineExtension.config.inline).toBe(true);
    expect(htmlInlineExtension.config.group).toBe("inline");
  });

  describe("parseHTML getAttrs", () => {
    const parseRules = htmlInlineExtension.config.parseHTML!.call({} as never)!;
    const getAttrs = parseRules[0].getAttrs as (el: HTMLElement) => Record<string, unknown> | false;

    it("extracts value from data-value", () => {
      const el = makeElement("span", { "data-type": "html", "data-value": "<kbd>K</kbd>" });
      expect(getAttrs(el)).toEqual({ value: "<kbd>K</kbd>" });
    });

    it("falls back to textContent", () => {
      const el = makeElement("span", { "data-type": "html" }, "<abbr>HTML</abbr>");
      expect(getAttrs(el)).toEqual({ value: "<abbr>HTML</abbr>" });
    });

    it("returns false for empty element without data-value", () => {
      const el = makeElement("span", { "data-type": "html" });
      expect(getAttrs(el)).toBe(false);
    });

    it("does not trim textContent fallback (inline preserves whitespace)", () => {
      const el = makeElement("span", { "data-type": "html" }, " content ");
      // textContent is " content " which is truthy
      expect(getAttrs(el)).toEqual({ value: " content " });
    });
  });
});

// ---------------------------------------------------------------------------
// htmlBlock
// ---------------------------------------------------------------------------

describe("htmlBlockExtension", () => {
  it("has correct name", () => {
    expect(htmlBlockExtension.name).toBe("html_block");
  });

  it("is a block atom", () => {
    expect(htmlBlockExtension.config.atom).toBe(true);
    expect(htmlBlockExtension.config.group).toBe("block");
    expect(htmlBlockExtension.config.isolating).toBe(true);
  });

  describe("parseHTML getAttrs", () => {
    const parseRules = htmlBlockExtension.config.parseHTML!.call({} as never)!;
    const getAttrs = parseRules[0].getAttrs as (el: HTMLElement) => Record<string, unknown> | false;

    it("extracts value from data-value", () => {
      const el = makeElement("div", { "data-type": "html-block", "data-value": "<div>block</div>" });
      expect(getAttrs(el)).toEqual({ value: "<div>block</div>" });
    });

    it("falls back to textContent", () => {
      const el = makeElement("div", { "data-type": "html-block" }, "<table>...</table>");
      expect(getAttrs(el)).toEqual({ value: "<table>...</table>" });
    });

    it("returns false for empty element without data-value", () => {
      const el = makeElement("div", { "data-type": "html-block" });
      expect(getAttrs(el)).toBe(false);
    });
  });
});

// ---------------------------------------------------------------------------
// linkDefinition
// ---------------------------------------------------------------------------

describe("linkDefinitionExtension", () => {
  it("has correct name", () => {
    expect(linkDefinitionExtension.name).toBe("link_definition");
  });

  it("is a block atom, not selectable", () => {
    expect(linkDefinitionExtension.config.atom).toBe(true);
    expect(linkDefinitionExtension.config.selectable).toBe(false);
    expect(linkDefinitionExtension.config.group).toBe("block");
  });

  describe("parseHTML getAttrs", () => {
    const parseRules = linkDefinitionExtension.config.parseHTML!.call({} as never)!;
    const getAttrs = parseRules[0].getAttrs as (el: HTMLElement) => Record<string, unknown>;

    it("extracts all attributes", () => {
      const el = makeElement("div", {
        "data-type": "link-definition",
        "data-identifier": "example",
        "data-label": "Example",
        "data-url": "https://example.com",
        "data-title": "Example Title",
      });
      expect(getAttrs(el)).toEqual({
        identifier: "example",
        label: "Example",
        url: "https://example.com",
        title: "Example Title",
      });
    });

    it("defaults identifier and url to empty string when missing", () => {
      const el = makeElement("div", { "data-type": "link-definition" });
      const attrs = getAttrs(el);
      expect(attrs.identifier).toBe("");
      expect(attrs.url).toBe("");
    });

    it("returns null for missing optional attributes (label, title)", () => {
      const el = makeElement("div", { "data-type": "link-definition" });
      const attrs = getAttrs(el);
      expect(attrs.label).toBeNull();
      expect(attrs.title).toBeNull();
    });
  });
});

// ---------------------------------------------------------------------------
// wikiLink
// ---------------------------------------------------------------------------

describe("wikiLinkExtension", () => {
  it("has correct name", () => {
    expect(wikiLinkExtension.name).toBe("wikiLink");
  });

  it("is inline with content", () => {
    expect(wikiLinkExtension.config.inline).toBe(true);
    expect(wikiLinkExtension.config.group).toBe("inline");
    expect(wikiLinkExtension.config.content).toBe("text*");
  });

  describe("parseHTML getAttrs", () => {
    const parseRules = wikiLinkExtension.config.parseHTML!.call({} as never)!;
    const getAttrs = parseRules[0].getAttrs as (el: HTMLElement) => Record<string, unknown> | false;

    it("extracts value from data-value", () => {
      const el = makeElement("span", { "data-type": "wiki-link", "data-value": "some-page" });
      expect(getAttrs(el)).toEqual({ value: "some-page" });
    });

    it("falls back to textContent when data-value missing", () => {
      const el = makeElement("span", { "data-type": "wiki-link" }, "target page");
      expect(getAttrs(el)).toEqual({ value: "target page" });
    });

    it("returns false when both data-value and textContent are empty", () => {
      const el = makeElement("span", { "data-type": "wiki-link" });
      expect(getAttrs(el)).toBe(false);
    });

    it("uses data-value over textContent when both present", () => {
      const el = makeElement("span", { "data-type": "wiki-link", "data-value": "target" }, "display text");
      expect(getAttrs(el)).toEqual({ value: "target" });
    });

    it("returns false for empty data-value (empty string is falsy)", () => {
      const el = makeElement("span", { "data-type": "wiki-link", "data-value": "" });
      // data-value="" is getAttribute => "" which is falsy
      expect(getAttrs(el)).toBe(false);
    });
  });
});
