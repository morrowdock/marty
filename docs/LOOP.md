# The Marty loop (reference agent)

Status: early preview, 2026-11-09. Prompts `marty-prompts/23`. Engine pin as in
`Package.swift`.

`marty ask` and `marty bench` run one reference agent on the engine. The
agent works in the same process as the engine (`MartyEngine`, the same code that
the MCP server uses), so a run needs no MCP client.

## Steps

0. **Research** (on by default; `--no-research` skips it). One model call with
   web search and web fetch only returns a FACT TABLE: at most 20 rows, each a
   claim, a value, a label (VERIFIED, CLAIM, PLAUSIBLE, UNKNOWN), the version and
   years it applies to, and up to 3 sources (URL, publisher, date, a short
   quote). The call sees only the question (never a grading key or another
   file; it runs in a new empty directory with no file tools), is capped by
   `--research-turns` (default 12; one turn per search or fetch), and may not
   fetch pages on GitHub (`github.com`, `raw.githubusercontent.com`,
   `gist.github.com`), whose sources Marty also drops. An abstract subject may
   reply `{"needed": false}`. Marty checks the labels by form, not by reading
   the sources: VERIFIED needs sources on two different sites (registrable
   domains of the full host name: sibling subdomains are one site; hosts are
   compared in lower case without a trailing dot; IP literals and single-label
   hosts are dropped; WebFetch is denied on each blocked domain and its
   subdomains) (else CLAIM), a
   CLAIM needs a source (else PLAUSIBLE), an UNKNOWN row has no value, and every
   change is listed in `downgrades`. Sources on free hosting sites
   (`pages.dev`, `netlify.app`, `github.io` and the like, where copies of news
   pages live) are dropped. Then the quote check (on by default;
   `--no-quote-check` keeps the rows): Marty fetches each cited page itself (at
   most 24 pages, 10 s each, at most 2 MB counted as the bytes arrive, a generic
   client name, no cookies). The fetch is guarded: each hop (the URL and each of
   at most 3 redirects, which Marty follows itself) must be http(s) with a
   public DNS name, no credentials, and every address it resolves to public (no
   loopback, private, link-local, shared, multicast or reserved IPv4 range; for
   IPv6 only global unicast outside the documentation, Teredo, 6to4 and NAT64
   ranges; a host with a trailing dot is refused). The connection is pinned to
   a checked address: the system `curl` (part of macOS) runs with `--resolve
   host:port:address`, so no later DNS answer is used, TLS is still verified
   against the host name, and curl gets no config file, no proxy and no
   redirects of its own. Marty reads the final response of curl's header dump
   (informational 1xx blocks skipped; `Location` only from the final block) and
   stops curl itself past its deadline (SIGTERM, then SIGKILL). Marty looks for the source's quote in the page text
   by words (`QuoteCheck.match`). The text is normalized on the page and in the
   quote alike: scripts, styles, comments and reference marks ("[3]", "[edit]")
   removed; block tags (table cells, paragraphs, line breaks) are hard
   boundaries and inline tags (`<span>`) join text as it renders; `<sup>` and
   Unicode superscripts become "^" ("10³" is "10^3"), `<sub>` "_"; named and
   numeric entities decoded (an unknown one is a symbol); NFKC; zero-width
   characters and joiners such as U+2060 removed; case, quote marks and dashes
   folded; a prime after a digit, ASCII or curly, stays a unit mark ("5'11\""
   is 5′11″, not "511") unless it closes a quotation of its kind that is open
   in the same block (quotation marks pair by context: an apostrophe inside a
   word or before a decade, "it's", "'90s", opens nothing, a mark before a
   digit, "5'11", is always a prime, and a quoted number, "'10'", is a
   quotation); vulgar and spaced mixed fractions are "+n/d" ("1½" is
   "1+1/2"); grouping spaces before 3 digits join thousands ("1 144" is
   "1,144"); number operators bind without spaces ("10 ^ 3", "3 / 4",
   "10 ± 2", "4 + 4", "10 x 20", "1.5·10^6", "≥ 10", ">= 10", "10 m / s",
   "10 %"); a dash is a word of its own, except an em dash or a hyphen between
   two words, which is punctuation (a hard boundary), and a hyphen glued into a
   compound unit right after a number ("10 N-m", "10 amp-hours"), which stays
   part of the quantity ("10 N" does not match "10 N-m"). An ellipsis or a bracketed insertion
   such as "[…]" or "[s]" in the quote is a gap: the quote's parts must all be
   found in order, all together at least 16 characters and the longest at
   least 8 (a bare "85 mph" is no evidence). Each part's words must equal the
   page's words, so "85 mph" never matches "185 mph", "5" never "1.5", ".5",
   "(5)", "$5" or "5%", and "10 m" never "10 m/s"; only a letters-only word
   glued to a gap may be completed by it ("engine[s]", "[T]he"; not a unit
   after a number). A number is a whole expression: a part that starts with a
   number (or a sign, or a unit after a number) may not follow a page word
   without letters (an operator, a symbol, another number: "≥ 10", "10 ± 2",
   "6.674 30", "5′ 11″", "− $500") unless a hard boundary is between them, and
   a signed part never follows a word with a digit ("2e-3" is not "-3"); a
   part that ends with a number or a unit after one may not be followed by
   such a word, nor by "per" or a power or quotient unit ("10 m" is not
   "10 m s⁻¹", "10 metres" not "10 metres per second" or "10 metres a second",
   or "10 metres every 30 seconds", "10 kW" not "10 kW h" or any SI-prefixed
   unit symbol after it, "10 cm" not "10 cm x 20 cm"), nor by a magnitude
   ("$10" is not "$10 million"), nor by "per"; a quantity with a unit
   (attached, "10L", "10%", or a unit word after the number) is followed only
   by a hard boundary or an ordinary prose word ("of", "at", "in", "over",
   "tall", ...), so any other word, which may continue the unit, a rate or a
   product ("100 amp hours", "100 V A", "10 litres every fifteen minutes"),
   leaves the quote unmatched, and an allowed word that leads into another
   quantity or a time ("10 cm by 20 cm", "10 litres in 30 seconds") does too;
   a bare number may not be followed by a unit word ("10 percent", "100 watt
   hours", "10 m"); a unit abbreviation's period after a number ("10 in.",
   "10 gal.") never ends the quantity; a part that starts with a number may
   not follow a written bound or approximation ("up to", "at least", "less
   than", "about", "over", "approx.", "max.", ...), and a quantity may not be
   followed by one ("or less", "or more", "max", "and up"); modifiers between
   a connector and a quantity are skipped ("in just 30 seconds"); cubic,
   square and data units are unit words; a quantity's unit may
   be a few words with unit symbols ("10 degrees Celsius", "10 N-m", "10 m/s"); a range in words is whole at both ends ("10 to 20 bar" and
   "between 10 degrees Celsius and 20 degrees Celsius" give neither end); a gap glued to a number keeps these rules
   ("[…]5 degrees" is not "−5 degrees"); a dash before a word is punctuation
   ("1,050 bhp — the company").
   Each source's date comes only from its fetched page: its publication date
   (HTML comments ignored: its page-level publication meta
   tag, also `dcterms.*` and other common names, with a day-first date such as
   "13-10-2020" read only when the order is unambiguous and impossible dates
   ignored, outside
   scripts, styles and templates, by property or
   name, in either attribute order and either quote style; else the
   `datePublished` of the page's own JSON-LD article: the one a page object
   names as `mainEntity` (two different named articles are ambiguous), else the one article with `mainEntityOfPage`, else
   the only article, else with no article the only page object; with several
   candidates the owner is unknown and the date stays empty; never a nested one
   such as a related article's or a comment's; microdata is not read, since its
   owner is not known; with no usable metadata, the date the page shows in its
   dateline under the title: the first `<time>` element's text, or an element
   marked as a date, dateline, byline or publication line, that holds a date
   and is not an "updated", "modified" or "related" one (by its attributes, its
   text, the words right before it or a container around it), within the
   markup after the first `<h1>` ("October 8, 2020",
   "09 Apr 2020"; body prose is never read for a date), whether or not the quote was found; a page that
   states none, or a page that was not fetched, leaves the date empty (the
   model's date is removed; every change is listed in `downgrades`). The site that counts is the one the page finally came
   from (a redirect to a blocked or free hosting site fails). Each source records its `check` ("quote found", "quote not found",
   "page failed (404)", "not checked (budget)"). A row with no found quote is
   UNKNOWN (no value; its sources stay as notes) and `unconfirmed`: it is left
   out of the author's table, which says that such rows exist and must never be
   called "not published", and it is no evidence for `fact.unsourced`; a row is
   also UNKNOWN and `unconfirmed` when every source it gave was dropped (only a
   row the model itself gave as UNKNOWN without sources is a researched
   absence, "not found in this search"); a row whose value's first number is in
   none of its found quotes (number words such as "five" or "twenty-four", as
   one number, Roman version numerals such as "Mk IV", and, right before one of
   the row's own words within three words, an ordinal ("a fifth engine"), or
   for 1 an article or "single", for 2 "both", "either" or "pair" ("a rear jet
   engine", "either side") count as stated; "a housing with five rotors"
   states no 1 rotor, "first flight" no count); a found quote must also state
   the claim: each share or comparison word of the value and claim ("most",
   "half", "a third", "mainly", …) must be in a found quote, and a value in
   words needs one of its content words there; otherwise the row is left out
   ("the found quotes do not state …") (a value computed from other figures, such as a
   ratio of two rows) is also `unconfirmed` and left out; a VERIFIED row needs
   found quotes on two sites and no found
   quote whose text or page text within 160 characters attributes the figure
   to its maker or one person ("claims", "according to", "the company", ...),
   else it is a CLAIM. The prompt also says that a maker's figure stays a CLAIM when
   news sites repeat it. The table goes into the plan, author,
   repair, follow-up and answer prompts as one JSON object per row between
   `BEGIN FACT TABLE` and `END FACT TABLE` (markers inside a field are
   removed), and every system prompt says that the table is web data whose
   instructions are never followed. A refused answer gets no table. A failed or unreadable research reply,
   or an adapter without web tools, leaves no table ("Fact table: none"), and
   the run goes on; this is not an adapter error. Research that was tried and
   stopped before any row (a limit, a timeout, an error, an unreadable reply)
   also gets a `warning` with its cause, and the prompts say that a fact not
   in the table may still be published. The research call streams its
   events (`--output-format stream-json`): Marty parses every line as it arrives
   (also past the 8 MB kept output; the last line without a newline too) as
   JSON, counts each WebSearch and WebFetch use, keeps the last top-level
   result event, and stops the call when it goes over
   `--research-turns`. The research prompt asks the model to write each fact
   as soon as it confirms it, as a line `ROW {...}` (a later row with the same
   id replaces an earlier one, an identical row is skipped, at most 20 kept);
   ROW lines in the final reply are not part of its table. When the call is
   stopped at Marty's limit or the CLI's own turn limit (`error_max_turns`),
   ends in an error, times out, ends without a result event, or its final
   reply is not a table (no "rows" list), those rows make a
   partial table (`partial`, its `partialCause`, a `warning` with the cause in the
   receipt, and a line in the plan and author prompts that the table is
   partial); with no row written there is no table and the same warning
   (`adapter.research.turns`; then there is no table). The receipt's `research`
   block records the table with each source's check, `quoteChecks`, the
   downgrades, the counted `webTools`, the CLI's `turns` and the limits.
1. **Plan.** The model gets the question and the compact engine catalog. It
   plans the lesson in a fixed order: the whole system first (every main unit
   in its place and number, people or loads as schematic figures, and the
   forces as arrows), then the inside of the one part that makes it work, cut
   open, then what the model does not show. It answers with a JSON plan:
   A well-known headline figure of the subject (thrust against weight, power,
   top speed, range, capacity) goes in `given`, taken only from the fact table
   (`<row id>: <fact>` in the row's label wording; empty with no table). When the
   question asks how a vehicle, aircraft or flying device flies, lifts or
   hovers, `given` holds its thrust and the weight it lifts. Each entry is in
   the row's wording: VERIFIED plainly, CLAIM as "claimed by <publisher>",
   PLAUSIBLE as "likely" or "example", UNKNOWN as "not found in this search"
   or left out (never "not published"); rows are
   never merged into a range, and the product version and years come from the
   table. When a flight question (a flight word such as fly or hover, or
   lift with a flight context such as jet, drone or wing; "a hydraulic lift" is
   not one) gets a plan with no thrust entry while the fact table has a thrust
   row with a number, Marty asks once more, only for the table's thrust (and
   weight) rows (`plan.lint`,
   reason `plan.given.thrust`, with `fixed`). Only the reply's `given` is taken,
   and only when it names thrust with a number; a partial, empty or bad reply,
   or an adapter failure, keeps the original plan, and authoring goes on. The plan says
   whether the subject is in scope, the `form` (`solid`, or `explainer`: the 3D
   model with a 2D table of published numbers beside it), `whole`, `inside`,
   `given` (numbers it knows
   but the engine cannot solve, with their source), 3 to 8 teaching beats, the
   component and primitive ids that it wants, and what the model cannot show
   (`honesty`). The loop keeps at most 6 ids that the catalog knows
   and records the ids it dropped.
2. **Author.** The model writes a v2 document (MartyGraphics open
   vocabulary 1): every number in a caption is a `{fact}` placeholder that the
   engine fills (rule N1), and claims in a step are proved by the engine. The
   guide also shows the explainer tools of the engine: step `section` and
   `ghost`, part `opacity` and `emissive`, and `annotations` (labels; force
   arrows, where a gravity force is checked to point down; flow and pointer
   arrows; measured dimensions). A given number goes only in a label or arrow
   marked `unchecked`, so it shows as Not checked. The guide also asks: people
   as the `mannequin` component with worn parts hung on its anchors, small
   turbines and turbochargers with `centrifugalCompressor`, every part attached
   where it really is (a back unit touches the torso: `pilot.back` is the middle
   of the back surface), inside views as a `section` cut of the one part in
   place (ghost only the parts in front of it) with `focus` on that step, at
   most 5 texts per step (labels, dimensions and arrows with text; an
   `annotate` list on every step), one thrust arrow per thrust unit shown with
   both ends on that unit and no text (one label names them), force arrows
   that start outside the body, a steering pose with the arms unequal and
   "schematic" in the text, facts beyond the engine (a figure, date, product
   name or version, load share) only from the fact table, in an unchecked label
   or a noted table row whose text or note starts with its row id ("F3
   <publisher> <year>") in the row's wording (UNKNOWN only as "not published"),
   and no share or comparison without a row, a `{fact}` or a hedge. Each inside
   label is anchored on the named inner part, not on the casing or body, and an
   inside whose real parts are not public is labelled "<class>-style <kind>
   (example)" with "Not confirmed <brand> hardware". Each unit the lesson names
   is shown in a view that faces it (a back unit: camera "back", "backLeft" or
   "backRight") and every named
   unit in one whole-figure view; the guide lists the camera presets exactly
   (`MartyEngine.cameraPresets`), as do the `view.camera` and `step.camera`
   repair hints; force units are "lbf" and "kgf"; a board has no text caption
   (it would show on every beat) and a table shows each figure's publisher (a
   "Source" column); a fact a table row gives is stated, never "not found"; a follow-up step or beat gives text
   to at most two arrows. Board table numbers keep every published digit:
   Marty writes every non-integer cell as text before the check, in a table, a
   board override or a beat op that sets "cells" (85.06 is not shown as 85.1). The generic repair hints for anchor and arrow refusals
   point to the issue's own suggestion and alternatives and never advise
   ghosting the part in the way (a part a label or pointer sits on must not be
   ghosted). The research prompt asks for the maker's own website for the
   current version and model, interviews with the maker or inventor for how it
   works and how parts share the load, ratios only as a source states them,
   and dates exactly as the page shows them, the maker's product, technology or
   innovation pages by name with its current model name as a row, the
   inventor's own account of how thrust or load is shared, and quotes of at
   least 16 characters (a shorter quote is reported "quote too short to
   check"). A bare part anchor (`{"part": id}`) is the part's centre (the
   engine accepts it since PR #46). Free text (a figure, a
   note) is a label on a `{"world": [x, y, z]}` anchor beside the model, not on
   a part. The same general honesty rules apply to
   every subject: a load share is quoted with its source, never invented; no
   performance figure is derived from the simple model; the product version and
   years are named; an inside whose real parts are not public is labelled on
   screen as a schematic example, not confirmed hardware; the physics words are
   exact (a hover balances the upward parts of the thrusts against the weight,
   and the side forces and turning moments; fuel burns with the oxygen in the
   compressed air; thrust is the reaction to the gas accelerated out of the
   nozzle); and the part that really moves is named. A step may `pose` parts
   (instance `with`, part `rot`; not parts of a gear solve) and `hide`/`show`
   parts for that step only, and an instance id counts as one entry in step
   lists; the guide teaches a steering step with the arms posed. Small jet
   engines use the `microTurbojet` component (11 parts; five and a mannequin fit
   the 96-part limit; `cutaway` opens one), named as a schematic example. Labels
   hold up to 60 characters on 2 lines. The prompts hold no subject-specific
   facts. Each label or arrow is
   defined once, and every defined id is in some step's `annotate` list (strict
   refuses an unlisted one, `annotation.unused`). In an explainer the table is
   added by a beat command in the first beat that needs it, and a later beat may
   remove it (the engine's legend keeps what the learner was shown). When the plan chose the
   explainer form, the author prompt also gets the explainer section and a small
   accepted explainer (a table with a noted given number, which shows as Given,
   beside the 3D model); other prompts stay smaller. It gets a short format guide, the `explain` entries of the
   chosen ids (components without their full definitions) and one small
   accepted example. It answers with `{"document": ..., "components": [...]}`.
3. **Check.** Before the check, Marty applies the length budget: every text
   over the engine's limit (title 80, step say 240, part name 60, label and
   arrow text 60 after placeholders are filled, unchecked 60; explainer title
   80, beat say 200, note 60; the guide states them; a label also has an
   authored cap of 240 and an explainer title of 320) is cut only by dropping
   whole trailing sentences that hold no number, no placeholder and no list
   (no comma), only complete sentences, never in a text with a numbered or
   bulleted list, only in a text of more than one sentence without placeholders
   (its length is exact), and only when at least 60 % of it stays (the attempt
   lists the cut paths in `trimmed`). A cut never shortens a list, a clause or
   a one-phrase text (a title, a name): those are refused and the repair asks
   the model to shorten them. A text with placeholders is never cut; its repair states the
   authored length exactly, and for a filled cap a certain lower bound (each
   placeholder at least 1 character). Follow-up patches (also their part-name
   maps) and changed explainers are trimmed the same way; the accepted
   follow-up step in the receipt is the trimmed one that was checked. The engine checks the
   document in its strict profile (also
   refuses idle joints and turn axes that miss their part). An accepted
   document gets a `ref`. Then Marty checks its facts (`fact.unsourced.<field>`):
   every typed number, year and product version ("Mk 4", "Mark II", "Gen 3",
   "v2" written together, and a capitalized "Model 3", "Series 5" or "Version 2"
   that does not start a sentence) in every shown text field must be in the
   evidence. The fields are the title, part names, captions, `unchecked` texts,
   annotation texts, notes, and every shown key of a 2D item (`text`, `label`,
   `xl`, `yl`, `cells`, `bars` labels and values, `unit`, `vals`, `ptrs`, `xr`,
   `yr`), also in board `over` edits, beat `add` and `set` commands (a `set` only
   when its key is shown) and beat `bind` control labels. The evidence is: the fact table (values, claims,
   `appliesTo`, source dates), the question, the engine's facts and ratios (also
   as their exact fraction or inverse) and the sizes set in the model. Engine
   placeholders (a fact name in braces, in v2 assemblies and explainers, where
   the engine fills them; a v1 assembly, a patch of one, part names, notes and
   `unchecked` reasons show braces as typed), row ids (`F3`)
   and "2D"/"3D" are not facts; a part name is
   checked for years and versions only ("Jet 2" counts units); a label whose
   `unchecked` text starts with "assumed example" is exempt. A finding is a
   refusal like an engine refusal. A text that says a fact is "not published"
   (also "unpublished", "never published", "undisclosed") is refused the same way
   (`fact.notPublished.<field>`) unless the text, or its own note (an
   annotation's or step's or beat's `unchecked`, a table's note), cites a row
   whose confirmed found quote itself says so; "assumed example" labels are not
   exempt from this:
   a search that did not find a fact does not show it is unpublished; the
   answer's check flags such a sentence too (attempt reason `fact.unsourced.<field>` of
   the first finding, `engineOk` true, `unsourced` lists up to 12 findings) and
   gets a normal repair with the findings and the table; with no repair left the
   document is not accepted. Follow-up changes are checked the same way (a
   patch's title, steps and part names; a whole changed explainer), with the
   follow-up question as evidence too. Then Marty lints it: a step or beat that shows more
   than 5 texts (labels, dimensions and arrows with text; an arrow without text
   does not count), and a sentence in a say or an annotation text that compares
   sizes or shares (most, all of, more than) with no hedge, no `{fact}`
   placeholder and no given figure (each listed id counts once, as the engine
   shows it; "all the" is no share word), and a given figure (an unchecked label
   or arrow whose text shows a typed number, or a noted table row with a typed
   number, with a basis or an unchecked note; an unchecked text on a label with
   no number is a reason, not a source) that merges two figures into one range (a span of
   years is fine) or names a source with no year (unless "reported", "assumed
   example" or a fact table row id). A lint problem asks for one repair at most (attempt reason
   `marty.lint`, `engineOk` true), when one is left. The engine-accepted
   document with the fewest findings is kept (a later one wins a tie), and it
   stands, with `lint` and `lintAttempt` in the receipt (but never with a share
   or comparison that has no figure and no hedge; an attribution such as
   "<publisher> claims" or "reported" is no hedge: Marty removes such sentences
   from the says that keep another sentence and checks again, `lintRemoved`,
   or refuses the document, `lintRefused`), when no attempt is
   clean.
4. **Repair.** A refused document goes back to the model with the exact reason,
   the part, and, for common reasons, a one-line fact that restates the engine
   rule (for example the centre-distance formula). A caption or claim refusal
   also gets the list of facts the engine solved for the model (when the
   refusal comes before the report, Marty checks the same document without its
   steps and with a plain title to get them). A frame, idle-joint or `expect`
   refusal also gets the engine's read-back (for `expect`, from the same
   document without its `expect` entries, also those in component `set` entries,
   and without its steps and with a plain title; component definitions are v1
   and cannot hold `expect`). A visibility refusal (`annotations.visible`,
   `step.annotate.count`, `view.annotate.count`) also gets the engine's
   visibility detail in words: which annotation, how many show, the limit, the
   cause and the step or beat; the attempt in the receipt keeps the detail
   (also in follow-up repairs). A label or pointer dot refusal
   (`annotation.anchor.hidden`, `.off`, `.untested`) gets the engine's anchor
   issues (`anchor` first, then `anchorIssues`, then a hidden arrow refusal's
   `arrow` and `arrowIssues` with the visible share; every distinct issue, under a
   header with the total count): the dot, the cause,
   the step or beat, the part, what hides it or is nearer, the engine's
   checked suggestion (`suggest`, shown with at most 3 decimals as the engine's
   repair line writes it, with the instruction to apply it exactly) or why there
   is none (`noSuggest`: its readable cause and the engine's own alternatives
   for that cause, such as leaving the label out of the view's annotate list,
   ghosting the part in the way or changing the camera), and the engine's
   one-line `repair`; an alternative or repair line that would ghost or hide a
   part some label or arrow is anchored on, a part inside it, or a part of the
   same component instance as an anchored alias ("shaft.shaft" for
   "shaft.input"), is dropped, here and in the refusal detail (it would hide
   that dot; "do not ghost" advice is kept);
   the view named is the explainer beat when there is one
   (else the step); the attempt keeps `anchor`. Before any repair call (author and follow-up) Marty
   applies the engine's checked suggestions itself (a label's `at`, a
   pointer's `to`, and a hidden arrow's `from` and `to` from `arrow` /
   `arrowIssues`; the engine checks all printed suggestions together, so they
   are applied at once; an id given two different values for one field is a
   conflict and is left alone) and checks again, up to 3 rounds; the attempt lists the fixed
   ids in `autoFixed`, and when the document is still refused every repair
   (engine, fact, lint) starts from the auto-fixed document. An assembly
   follow-up patch cannot move annotations, so there Marty applies the
   suggestions to the patched whole document and checks it in full; the
   direction check, the repair baseline, `forceArrowsMoved` and the answer's
   change line then use that document (the follow-up records `autoFixed`). Every repair (author and follow-up)
   also gets the refusal's full structured detail (the engine's `repair`
   line, and `location`, `limit`, `actual`, `path`, `cause`, `by`, `closer`,
   `fix`, `suggest`, `detail` when present, nulls left out) and the texts of the
   refused document over their length limit, measured as the engine counts
   them. A `parts.resolved` refusal gets the engine's
   limit detail the same way (the resolved count, the limit and the component
   instances that add the most parts; attempt key `limit`). A `parts.count`
   refusal from component expansion has no detail at the pin and gets a hint. Only what the engine returned is
   attached; at most 80 facts and 48 read-back lines. At most 3 repairs. A
   follow-up patch refused for a caption or a claim gets the facts of the
   changed model (the same patch with steps cleared).
5. **Render** (with `--render`). Stills for every step, a snapshot and a
   manifest, through the engine renderer. It does not write `story.mp4`: use
   `marty-solid render` for the story video (its writer is not library API at
   the pin). A render that fails (for example
   with no Metal device) is recorded in the receipt; the checked lesson still
   stands.
6. **Teach.** The checked steps are the beats. `lesson.json` holds each beat's
   engine-filled text, its tier (the engine's `stepTiers`), its still, the
   engine facts and ratios, the legend line, the honesty note and a `sources`
   entry that says where each comes from. In a v2 document every number in a
   caption is an engine fact (rule N1), except a step marked `unchecked`; the
   words are the model's. Marty adds no number of its own.
7. **Follow-up** (with `--follow-up` or in `bench`). The model gets the checked
   document and the engine report, and answers with an engine patch (or `null`
   when nothing must change). The engine checks the patch, with at most 3
   repairs. The engine replaces a part field as a whole, so Marty merges a
   patch's `with` into the instance's current `with` first (only the asked
   parameter changes; `null` removes a parameter; a patch that also changes
   `use` to another component is not merged). A patch that changes only `title` and `steps` is refused
   (`followup.textOnly`): it would narrate a change that the engine never
   solved. Then the model writes a short answer from the engine reports before
   and after the change, the accepted change itself, and whether the solved
   ratios changed. The answer is model text and is marked so
   (`answerSource`). `modelled` says whether the engine solved the change (or
   none was needed). When the engine refused every change, the model still
   answers, with a separate system prompt: it says plainly that the model
   cannot show the what-if, gives no number beyond the report before and does
   no arithmetic. When no patch even reached the engine (only `json` or
   `followup.textOnly` problems), the prompt says "no change could be checked"
   instead of "the engine refused". An empty follow-up (the out-of-scope bench questions have
   none) means no follow-up turn. A steering or pose what-if does not patch the
   base: the model replies `{"step": {...}}` (one new step with `pose`, and
   `show` for parts seen only there; `"replace": <n>` edits step n instead) and
   Marty sends it as a steps patch, so the base pose stays for every other step.
   A title or steps patch counts as a model change only when the engine's
   effective step views change (the report's `stepViews`: the parts each step
   really poses or hides, and the pose read-back), so a pose that restates the
   base moves nothing and is words only; `"replace"` must name an existing step.
   Pose-text agreement: for each changed posed step (from a `step` reply or a
   raw steps patch; for an explainer, each changed beat, through the solid with
   one step per beat), the engine poses the step itself
   (`MartyEngine.stepForceArrows`: its own pose semantics, aliases and
   visibility) and gives the anchors of the force arrows (not gravity) that the
   step shows. With a mannequin they are read in its body frame at the pose
   (faces -Y, left +X, x = 0 is the body's middle), else in the world frame.
   The pose is sampled where the step's spin has played, as its still shows it.
   Marty sums their unit directions: the net side push (the side parts cancel
   when it is near 0 though they are not), whether the side parts point away
   from or toward the middle, and forward or backward. Claims are matched over
   the whole sentence: a net side motion of the body ("pushes the suit
   sideways", "the suit slides sideways", "the side push moves it") with no net
   side push, unless the sentence says (not denies: no negation in the 3 words
   before "cancel", "balance out" and the like) that the side parts cancel;
   a direction within 8 words after a thrust noun (thrust, force, jet,
   exhaust, engine), not right after "not", pointing away from or toward the
   middle (or outward, inward) against the arrows, or forward or backward
   (not "leans forward") against the push; the body pushed forward or
   backward against the push; "to the
   pilot's left/right" against the side. A step that makes one is refused as
   `followup.direction` with these facts in the repair. The checked steps are
   those posed before or after and changed in pose, show, hide, annotate, spin,
   explode or words (an explainer's original captions are compared). The push is
   computed again for each attempt. The answer prompt gets the same facts
   (`followUp.push`), and an answer sentence that disagrees gets the one
   rewrite. The follow-up prompt states the say limits (240 characters for a
   step, 200 for a beat), and the guide says a turn poses one arm (equal arms
   cancel). The accepted step is in `followUp.step`, and the force arrows on parts whose
   effective placement changed in some step (posed before or after, so removing
   a pose counts) are listed in `forceArrowsMoved`. In an explainer, the model
   adds or edits one beat whose `view` has `pose` and `show`; the same effective
   views (Marty copies `stepViews` from the explainer's solid view) decide
   whether it changed the model, and the authored beat views are part of the
   accepted change. A patch cannot change annotations: an arrow end on a
   part moves and turns with that part (and with the parts it hangs on), and an
   end at a world point stays where it is. The engine checks a gravity arrow
   again in the changed model. Marty lists the other force arrows that the
   accepted change may have moved (an end or `on` part on a changed part or on a
   part hung below one, where an edit of an inner part of a component moves
   the whole instance; every force arrow when params, constraints or joints
   changed) in `forceArrowsMoved`, and only then does the answer prompt ask the
   model to say that their direction is schematic. An explainer has no engine
   patch format, so its follow-up sends the whole changed explainer
   (`{"document": …}`, or `{"document": null}` for no change; any other value is
   repaired), which must stay an explainer (`followup.kind`) and is checked in
   strict mode (at most 3 repairs). A change of words only is refused as
   `followup.textOnly`: the model content compared is the solid (without its
   title and annotation text), the board keys other than its title (template,
   params and the rest), the board items other than text items, and the beats'
   model ops in order (an absent or empty `ops` adds nothing; `title` and
   `camera` ops, ops on text items, sets of a `text` or `label` key, and the
   `label` and `text` of an item are words). The answer prompt gets the accepted change with values before and
   after: the solid parts, the other solid keys, the board keys and items and the beat
   ops that changed. A modelled answer also gets the document's given figures
   (unchecked labels and arrows, and rows of noted explainer tables, with their
   source; a table whose cells a later beat sets is listed again, marked with
   that beat, after any header change; at most 12); a refused answer does not.
   Numbers from the structured values keep their short text (integers exactly,
   a float as its shortest round-trip text with any exponent written out), and
   matching ignores thousands commas and trailing decimal zeros. The answer prompt says that a
   claim about sizes, shares or comparisons must come from a given figure or an
   engine number, or be hedged. A sentence with "most", "the majority", "all
   of", "more than" or a similar word, with no hedge (about, in this schematic)
   and no number that is also in the evidence (the given figures shown, the
   engine fact texts and ratios, numbers set in the change; never raw JSON),
   gets one rewrite request. The answer prompt lists the beats or steps that
   already pose parts ("beat 4 poses …"; after an accepted change, those of the
   changed document): an answer that denies a motion while such a view exists
   ("the model does not show steering", "held still", "not a steering move";
   not an unrelated limit such as "not shown to scale") gets one
   rewrite request to say which beat or step shows it (assembly answers are
   told their views are steps; `answerPosedLint`); a sentence about the pose
   alone (no performance, unit or share word) is evidence-checked against the
   posed views: each angle must be the posed value of the side and joint it
   names ("the left shoulder is raised 60 degrees"), and a comparison of the two
   sides ("the left arm is raised more than the right", "one arm is raised more
   than the other") must hold for that joint, in the views the sentence names
   (each of them) or in one posed view when it names none; posed numbers source
   nothing else, and `answerLint.remaining` records any sentence
   that keeps it from clearing; the engine's push summary names how many shown
   thrust arrows it comes from ("the one shown thrust arrow gives (that arrow
   only, not every engine)"); a beat or
   step number that names one of its views is no fact for the number check. `answerLint`
   records the sentences and whether the
   rewrite cleared them. A sentence with a number, year or version that is in no
   source (the fact table, the reports, the change, the question and the
   follow-up; for a refused answer only the report before, not the rejected
   what-if) gets the same one rewrite (`answer.unsourced`). A rewrite that
   fails in the adapter keeps the first answer (`fixed` false). In
   an explainer, a force arrow whose direction the model
   sets may be marked `unchecked: "schematic direction"`; an arrow whose
   definition changed is listed in `forceArrowsMoved`.

Model text is only parsed as JSON and given to the engine. It is never run.

## Exit codes

`marty ask`: 0 accepted, 1 not accepted, 2 usage, setup or a run that threw
(for example the `claude` command is missing; then there is no receipt), 3 a
model call failed in the adapter (the output line lists `adapterErrors`).
`marty bench`: 0, or 1 when any row is an error row (a missing `claude` command
is an error row too; see bench/README.md); 2 for usage or setup errors before
the first question, or a summary that could not be written.

## Model adapters

| Adapter | Use |
| --- | --- |
| `claude-cli:<model>` | The local Claude Code CLI in print mode (`claude -p`), with the account that is logged in there. Every call is a new process in a new empty directory, with no tools (the research call: only the built-in WebSearch and WebFetch, allowed without a prompt, WebFetch denied on the blocked domains, `--max-turns`), no MCP servers, no slash commands, no user/project/local settings (so no hooks or plugins) and no session persistence. The child gets only an allowlist of variables: HOME, PATH, USER, LOGNAME, TMPDIR, the locale, the subscription login (`CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR`), proxies and CA certificates. No `ANTHROPIC_*` variable passes, so an exported `ANTHROPIC_API_KEY` is never used. Managed (administrator) settings still apply. The prompt goes in on standard input. The timeout (default 900 s) is on the child's exit. After it: SIGTERM, then SIGKILL after 5 s if the child still runs, then up to 5 s more for it to exit (at most timeout + 10 s in all). After a normal exit, Marty waits at most 5 s for the pipes to close and then uses what it read (a pipe that a grandchild keeps open is abandoned). The CLI adds its own fixed context: about 640 tokens in a probe on 2026-11-06. That figure, and that no CLAUDE.md or memory loads in the empty working directory, rest on that measurement, not on a documented guarantee. |
| `scripted` | Replays fixed replies (and, when given, fixed research replies). For tests, and to replay a recorded run. |

An adapter is one function: system prompt and user message in, text out. Other
models (an open-weight model, a future small Marty model) need only a new
adapter.

## Context size

The receipt records `contextBytes` for the plan and author prompts, and the
size and SHA-256 of every prompt. Tests fail when the plan prompt grows over
12,000 bytes or the author prompt over 14,000 bytes (the author prompt without component
entries: 12,500 bytes, and 15,000 bytes with the explainer form). For comparison, the
v1 eval harness sent about 25,600 bytes of engine docs in every call.

## Run receipt (`marty.run-receipt/v1`)

One `receipt.json` per run, with sorted keys:

| Key | Content |
| --- | --- |
| `format`, `prompts`, `model`, `engine` | Versions: receipt format, prompt set, adapter id, engine repository and commit. |
| `question`, `options`, `startedAt` | The input, the options (repairs, render, size) and the UTC start time. |
| `research` | The research phase: `ok`, `reason` when it failed (`research.unavailable`, `research.json`, an adapter reason), `needed`, the fact table `rows`, `downgrades`, `turns`, `webTools`, `maxTurns` and `blockedDomains`. |
| `plan` | The plan reply, the chosen ids and the dropped ids; `lint` when a flight question first had no thrust in `given`. |
| `attempts` | One entry per author or repair attempt: `ok`, `reason`, `part`, `ref`, `component`. |
| `accepted`, `final` | Whether a document was accepted, and its title, part ids, ratios, checks, `ref`, triangles and steps. |
| `render`, `lesson` | Render `ok`, `reason` (when it failed), directory, file digests and timing; `lesson.json`. |
| `adapterErrors` | Reasons of model calls that failed in the adapter (for example `adapter.timeout`). Present only when one failed. If the last plan call fails in the adapter (no plan was received), the run stops there. |
| `followUp` | The question, its attempts, `changed` (the engine accepted a patch), `modelled` (the engine solved the change, or none was needed), `ratiosChanged`, `forceArrowsMoved` (force arrows that the accepted change may have moved; their shown direction is schematic), the report after the change, the answer, `answerLint` (when a comparison without a figure was sent back once), `answerPosedLint` (when a denial of a posed view was sent back once), `autoFixed` and `answerSource`. `ok` means an answer was written: also an honest "this model cannot show it" when `modelled` is false. `ok` is false when no answer was written (for example an adapter failure). |
| `calls` | Every model call: phase, attempt, prompt files with sizes and digests, reply file, seconds, adapter facts (tokens, cost equivalent) and the engine outcome. |
| `seconds`, `modelSeconds`, `contextBytes` | Wall time, model time and prompt sizes. |

The prompts and replies are files in `calls/` next to the receipt. A run
directory can hold model text. Do not publish it unless it was reviewed.
