---
name: language-proofreading
description: Typography and grammar rules for proofreading e-commerce content. Provides language-agnostic universal rules plus per-language packs for English, Slovak, Czech, German, French, and Spanish. Use when auditing product descriptions, blog articles, or meta tags.
---

# Language proofreading

## Setup

This skill expects `audit.config.json` at the repo root with at least:

```json
{
  "report": { "language": "en" }
}
```

Use `report.language` to pick which language pack below applies. If the configured language is not listed, fall back to **Universal rules** plus the agent's general best judgment, and tell the user the language is not yet supported.

## Universal rules (apply to every language)

### Spaces
- No double spaces inside text
- No space before punctuation: `.`, `,`, `!`, `?`, `;`, `:` (exception: French)
- Single space after punctuation
- No trailing whitespace at end of lines

### Ellipsis
- Always the ellipsis character `…` (U+2026), never three periods `...`

### Dashes
- Hyphen `-` (U+002D) — for compound words: `state-of-the-art`
- En-dash `–` (U+2013) — for ranges: `5 – 10 days`, `London – Paris`
- Em-dash `—` (U+2014) — for parenthetical asides (English convention)

### Apostrophe
- Use the typographic apostrophe `'` (U+2019), not straight `'`

### Numbers and units
- Space between number and unit: `5 g`, `10 cm`, `100 €`, `15 %` — not `5g`, `100€`, `15%`
- Exception: `°C`, `°F` — space before degree, no space between degree and letter: `25 °C`

## Language packs

### English (`en`)
- Quotes: outer double, inner single — `"He said 'hello'"`
- Curly preferred: `" "` and `' '` over straight `" "` / `' '`
- Decimal separator: period `.`
- Thousands separator: comma `,` (e.g., `1,234.56`)
- Oxford comma: project-dependent — flag inconsistencies, not the choice itself
- Title case vs sentence case for headings: project-dependent — flag inconsistencies

### Slovak (`sk`)
- Quotes: `„lower-99 + upper-66"` — `„text"` (`„` U+201E, `"` U+201D)
- **Never** use English `"text"` in Slovak content
- Decimal separator: comma `,` (e.g., `12,5 cm`)
- Thousands: space or period (`1 000` or `1.000`)
- En-dash for ranges with spaces: `5 – 10 dní` (in Slovak the en-dash takes spaces)
- Non-breaking space (`&nbsp;`) between a single-syllable preposition and the following word: `s&nbsp;priateľmi`, `v&nbsp;Bratislave`
- Common Czechisms to flag: `naviac` → `navyše`, `ako náhle` → `akonáhle`, `propiska` → `pero`, `tužka` → `ceruzka`, `ohľadne` → `čo sa týka`

### Czech (`cs`)
- Quotes: `„lower-99 + upper-66"` (same as Slovak)
- Decimal separator: comma
- En-dash in numeric ranges WITHOUT spaces is allowed: `5–10 dnů`
- Common Slovakisms to flag: `naviac` → `navíc`, `akonáhle` (Slovak) → `jakmile`

### German (`de`)
- Quotes: `„unten oben"` — `„Text"`
- Decimal separator: comma
- Thousands: period (`1.000,00`)
- Capitalize all nouns (this is grammatical — flag missed capitalization)
- En-dash for ranges with spaces: `5 – 10 Tage`

### French (`fr`)
- Quotes: French guillemets `« texte »` with non-breaking spaces inside
- **Non-breaking space before** `:`, `;`, `!`, `?`, `»`
- Decimal separator: comma
- En-dash for ranges with spaces

### Spanish (`es`)
- Quotes: `«texto»` (preferred) or `"texto"` or curly
- Inverted opening punctuation: `¿Pregunta?`, `¡Exclamación!` — flag missing inverted marks
- Decimal separator: comma
- En-dash for ranges with spaces

## Detection heuristics (pseudocode)

```
# Universal: missing space before unit
match /\d+(g|kg|cm|mm|m|€|%|°C|°F)\b/ where no preceding space → flag

# Universal: triple-period ellipsis
if "..." in text → flag "use … (U+2026)"

# Universal: double space
if "  " in text → flag

# English / many languages: straight quotes where curly preferred
if /"[^"]+"/ in text and language uses curly → flag

# Slovak / Czech / German: English-style quotes
if language in [sk, cs, de] and /"[^"]+"/ in text → flag

# Slovak / Czech: hyphen in numeric range
if language in [sk, cs] and /\d+\s*-\s*\d+\s*(dní|dnů|...)/ → flag "use en-dash –"
```

## Output format

For each finding, emit:

```
- **[Category]:** "exact text" → "suggested fix" *(in section X)*
```

Examples:

```
- **Typography (en):** "the rule" → "the rule" — use curly quotes
- **Typography (sk):** "5 - 10 dní" → "5 – 10 dní"
```
