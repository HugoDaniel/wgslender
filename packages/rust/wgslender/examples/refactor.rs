//! Renaming, locating and removing symbols — the crate's largest module.
//!
//! ```text
//! cargo run -p wgslender --example refactor
//! ```
//!
//! There are two ways to say which symbol you mean, and the module is built
//! around the difference. A **byte offset** is what an editor has: the cursor.
//! A [`StableId`] is what a program has after the file moved under it. The
//! first two sections are the same symbol reached both ways; the third makes
//! edits with it; the fourth is the module's third answer shape, which is
//! neither a result nor an absence but a refusal.
//!
//! Every offset below is derived from the source rather than typed in, for a
//! reason worth stating once: `demo.wgsl` mentions `luminance` in its header
//! comment before it declares it, so `find("luminance")` lands at 93, inside a
//! comment, where every call in this module answers `None` or "symbol not
//! found". `find("fn luminance") + 3` is the offset of the declaration.

// The module rather than its functions: `refactor::rename` at a call site says
// which half of the crate the call belongs to, and the two halves answer a bad
// input differently. The types come in by name — they read as types wherever
// they appear.
use wgslender::{
    Error, Strictness,
    refactor::{self, ByteRange, Edit, IncludeDeclaration, RefactorError, StableId},
    validate,
};

/// The package's own fixture, and one of the two files it publishes.
const DEMO: &str = include_str!("../tests/fixtures/demo.wgsl");

/// A shader with something in it that can be deleted. `demo.wgsl` has nothing
/// removable — take any declaration out of it and the rest stops compiling.
const REMOVABLE: &str = "\
@group(0) @binding(0) var<storage, read_write> data: array<f32>;

fn unused_helper(value: f32) -> f32 {
    return value * 2.0;
}

@compute @workgroup_size(1)
fn main(@builtin(local_invocation_index) i: u32) {
    data[i] = f32(i);
}
";

fn main() -> Result<(), Error> {
    by_offset()?;
    by_stable_id()?;
    edits()?;
    failures()
}

/// What an editor has: a cursor somewhere in the text.
fn by_offset() -> Result<(), Error> {
    heading("1. by offset — the cursor");

    let cursor = declaration_of("fn luminance", DEMO);
    println!(
        "the cursor is at byte {cursor}, on {:?}",
        word_at(DEMO, cursor)
    );

    for include in [IncludeDeclaration::Yes, IncludeDeclaration::No] {
        let references = refactor::find_references(DEMO, cursor, include)?;
        println!(
            "\nfind_references(demo, {cursor}, {include:?}) -> {}",
            plural(references.len(), "reference")
        );
        for reference in &references {
            println!(
                "  {:>3}..{:<4}{:<10}{:?}",
                reference.start,
                reference.end,
                if reference.is_write { "write" } else { "read" },
                line_containing(DEMO, reference.start),
            );
        }
    }

    println!(
        "\nThe extra reference under `Yes` is the declaration itself, and it is the\n\
         one marked `write`: declaring a name writes it. Which of those two answers\n\
         you want depends on the question — highlight-under-caret wants the\n\
         declaration in, \"where is this used?\" wants it out — and neither is the\n\
         obvious default, which is why the parameter is `IncludeDeclaration::Yes`\n\
         rather than a bare `true` for a reader of the call site to guess at.\n\
         \n\
         This is also the one call in the module a cursor can be pointed at blindly:\n\
         an offset that names no symbol is an empty list, not a failure."
    );

    let nothing = refactor::find_references(DEMO, 0, IncludeDeclaration::Yes)?;
    assert!(
        nothing.is_empty(),
        "byte 0 is inside a comment and names no symbol"
    );
    println!(
        "find_references(demo, 0, Yes) -> {}",
        plural(nothing.len(), "reference")
    );
    Ok(())
}

/// What a program has: a name for the symbol that outlives the offset.
fn by_stable_id() -> Result<(), Error> {
    heading("2. by stable id — the same symbol, named");

    let cursor = declaration_of("fn luminance", DEMO);
    let Some(id) = refactor::stable_id_at_offset(DEMO, cursor)? else {
        println!("no symbol at {cursor} — the offset is wrong, see the module comment");
        return Ok(());
    };
    println!("stable_id_at_offset(demo, {cursor}) -> {id}");

    let name = refactor::locate_stable_id(DEMO, &id)?;
    let declaration = refactor::locate_declaration(DEMO, &id)?;
    println!("\nlocate_stable_id     {}", describe(DEMO, name));
    println!("locate_declaration   {}", describe(DEMO, declaration));

    println!(
        "\nTwo questions, two answers: where the *name* is written, and where the\n\
         whole declaration is. A rename needs the first; a jump-to-definition or a\n\
         fold wants the second.\n\
         \n\
         What the id buys is the thing an offset cannot do. Insert one character at\n\
         the top of the file and every offset below it is wrong; the id still finds\n\
         the symbol, because it names the symbol rather than a position. It is opaque\n\
         — a token to hand back, not a path to take apart — and `Ok(None)` is its\n\
         honest answer for a file that no longer declares it:"
    );

    let elsewhere = "@compute @workgroup_size(1)\nfn main() {}\n";
    println!(
        "  locate_stable_id(another shader, {id}) -> {:?}",
        refactor::locate_stable_id(elsewhere, &id)?
    );

    // The offsets moved; the id did not — which is the section's whole claim, so
    // it is asserted rather than left to a reader comparing two printed numbers.
    let shifted = format!("// a line that was not there before\n{DEMO}");
    let moved = refactor::locate_stable_id(&shifted, &id)?;
    assert!(
        moved.is_some_and(|range| Some(range) != name),
        "the id should still find the symbol, at its new offset"
    );
    println!(
        "  locate_stable_id(demo with a line prepended, {id}) -> {}",
        describe(&shifted, moved)
    );
    Ok(())
}

/// The three edits: rename, retype, remove.
fn edits() -> Result<(), Error> {
    heading("3. the edits");

    renaming()?;
    retyping()?;
    removal()
}

/// Rename, both ways: a list of edits to splice yourself, and the same rename
/// applied for you.
fn renaming() -> Result<(), Error> {
    let cursor = declaration_of("fn luminance", DEMO);
    let id = StableId::new("v1:fn:luminance");

    let planned = refactor::rename_by_id(DEMO, &id, "relative_luminance")?;
    println!(
        "rename_by_id(demo, {id}, \"relative_luminance\") -> {} edits",
        planned.len()
    );
    for edit in &planned {
        println!("  {:>3}..{:<4}-> {:?}", edit.start, edit.end, edit.new_text);
    }

    let applied = refactor::rename_apply(DEMO, cursor, "relative_luminance")?;
    println!(
        "\nrename_apply(demo, {cursor}, \"relative_luminance\") -> {} bytes, was {}",
        applied.source.len(),
        DEMO.len(),
    );

    // The same edits, spliced by hand. Back to front, because an edit's offsets
    // are against the original source and applying the first one would move
    // every offset after it.
    let mut buffer = DEMO.to_owned();
    for edit in planned.iter().rev() {
        buffer.replace_range(edit.start as usize..edit.end as usize, &edit.new_text);
    }
    // Both routes reach the same text, or the `_apply` forms are not the
    // shortcut this section says they are.
    assert_eq!(
        buffer, applied.source,
        "hand-spliced edits diverged from rename_apply"
    );
    println!(
        "the same edits applied back to front by hand: {} bytes, identical: {}",
        buffer.len(),
        buffer == applied.source,
    );
    // How far the second edit's offsets would be wrong if the first were
    // applied first — the reason the loop above runs backwards.
    let drift = planned.first().map_or(0, |edit| {
        edit.new_text
            .len()
            .saturating_sub((edit.end - edit.start) as usize)
    });
    println!(
        "\nEdits in one result are ordered by `start` and never overlap, which is what\n\
         makes that loop safe. Front to back it would not be: the first replacement is\n\
         {drift} bytes longer than what it replaced, so every offset after it would be\n\
         {drift} bytes stale by the time it was used. Either iterate in reverse, or use\n\
         the `_apply` form and let the library do it."
    );
    Ok(())
}

/// Retyping a variable, from an id a tool stored earlier rather than a cursor.
fn retyping() -> Result<(), Error> {
    // A literal id, which is what a tool that stored one earlier would hold.
    let params = StableId::new("v1:var:params");
    println!("\nthe type edit, from a stored id: {params}");
    println!(
        "  locate_stable_id   {}",
        describe(DEMO, refactor::locate_stable_id(DEMO, &params)?)
    );
    println!(
        "  locate_type        {}",
        describe(DEMO, refactor::locate_type(DEMO, &params)?)
    );
    let retype = refactor::change_type(DEMO, &params, "Uniforms")?;
    for edit in &retype {
        println!(
            "  change_type        {:>3}..{:<4}-> {:?}",
            edit.start, edit.end, edit.new_text
        );
    }
    println!(
        "\n`change_type` splices the text in verbatim. It checks that there is an\n\
         annotation to replace and that the replacement is not empty, and nothing\n\
         else — \"Uniforms\" is not a type this shader declares, and the edit was\n\
         produced anyway. Validate the result unless the string came from your own\n\
         code."
    );
    Ok(())
}

/// Removal, and the whitespace it leaves behind.
fn removal() -> Result<(), Error> {
    let cursor = declaration_of("fn unused_helper", REMOVABLE);
    let Some(id) = refactor::stable_id_at_offset(REMOVABLE, cursor)? else {
        println!("\nno symbol at {cursor} in the removable source");
        return Ok(());
    };

    let edits = refactor::remove_declaration(REMOVABLE, &id)?;
    println!("\nremove_declaration(a shader with an unused helper, {id})");
    for edit in &edits {
        println!(
            "  {:>3}..{:<4}-> {:?}  ({} bytes deleted, nothing inserted)",
            edit.start,
            edit.end,
            edit.new_text,
            edit.end - edit.start,
        );
    }

    let applied = refactor::remove_declaration_apply(REMOVABLE, &id)?;
    println!(
        "\nremove_declaration_apply -> {} bytes, was {}. Verbatim, with the line\n\
         numbers this example is adding and the file is not:",
        applied.source.len(),
        REMOVABLE.len(),
    );
    for (number, line) in applied.source.lines().enumerate() {
        println!("  {:>2} |{line}", number + 1);
    }
    let blanks: Vec<String> = applied
        .source
        .lines()
        .enumerate()
        .filter(|(_, line)| line.trim().is_empty())
        .map(|(index, _)| (index + 1).to_string())
        .collect();
    println!(
        "\nLines {} are the hole. Two of those blanks were already in the source, one\n\
         on each side of the helper; the third is the newline its closing brace used\n\
         to sit on, which the edit stopped short of. It removes the declaration, not\n\
         the whitespace around it — an editor doing this for a human would want to\n\
         close the gap itself, and one splicing into a build artifact probably does\n\
         not care.\n\
         \n\
         The other half of the caveat is worse and is not visible here: removal takes\n\
         out the declaration and leaves every call to it in place. This helper was\n\
         uncalled, so the result still validates. Remove something used and it will\n\
         not — check `find_references` first, or `validate` after, which is what this\n\
         does:",
        blanks.join(", ")
    );
    let verdict = validate(&applied.source, Strictness::Default)?;
    assert!(
        verdict.valid,
        "removing an uncalled helper left the shader invalid"
    );
    println!("  validate(the result) -> valid: {}", verdict.valid);
    Ok(())
}

/// The refusals — and the absences they are carefully not confused with.
fn failures() -> Result<(), Error> {
    heading("4. what refusal looks like");

    let cursor = declaration_of("fn luminance", DEMO);
    attempt(
        "rename(demo, the declaration, \"fn\")",
        refactor::rename(DEMO, cursor, "fn"),
    );
    attempt("rename(demo, 0, \"x\")", refactor::rename(DEMO, 0, "x"));
    attempt(
        "rename_by_id(demo, \"v1:fn:nope\", \"x\")",
        refactor::rename_by_id(DEMO, &StableId::new("v1:fn:nope"), "x"),
    );

    println!(
        "\nAnd the same \"it is not there\" condition, asked as a question instead:\n\
         \x20 locate_stable_id(demo, \"v1:fn:nope\")  -> {:?}\n\
         \x20 locate_type(demo, \"v1:fn:luminance\")  -> {:?}",
        refactor::locate_stable_id(DEMO, &StableId::new("v1:fn:nope"))?,
        // `luminance` returns f32, so this one *is* found — the `None` above is
        // the absence, not this call being incapable of an answer.
        refactor::locate_type(DEMO, &StableId::new("v1:fn:luminance"))?
            .map(|range| slice(DEMO, range).to_owned()),
    );

    println!(
        "\nThat is the module's rule, and it is worth internalising because it is the\n\
         opposite of the rest of the crate. A bad shader is not an `Err` anywhere\n\
         else — `validate` reports it and returns `Ok`. Here, asking *about* something\n\
         absent is a fine question with the answer no, and it comes back as\n\
         `Ok(None)`; asking to *edit* something absent is a broken request, and there\n\
         is no edit list that usefully means \"what you asked for is impossible\".\n\
         `refactor` and `compile` are the crate's only two `Err`-on-bad-input calls."
    );
    Ok(())
}

/// Run one call that was meant to fail, and say why it did in words.
fn attempt(label: &str, outcome: Result<Vec<Edit>, Error>) {
    match outcome {
        Ok(edits) => println!("{label:<44}Ok, {} edits", edits.len()),
        Err(Error::Refactor(error)) => println!("{label:<44}Err — {}", reason(&error)),
        // Not a refusal but a broken call: print it rather than swallow it.
        Err(other) => println!("{label:<44}Err — {other}"),
    }
}

/// This example's word for each refusal.
///
/// A `match` rather than the `Display` the error already carries, because of the
/// last arm. `RefactorError` is `#[non_exhaustive]`, so a reason a newer library
/// reports arrives as `Other` rather than failing to parse, and somewhere a
/// caller has to decide what to do with a refusal it has never heard of. Here
/// that is a printed line; an editor would keep the buffer and say nothing
/// happened.
fn reason(error: &RefactorError) -> String {
    match error {
        RefactorError::InvalidIdentifier => "`fn` is a keyword, not a name".to_owned(),
        RefactorError::SymbolNotFound => "nothing is declared there".to_owned(),
        RefactorError::ParseError => "the source did not parse".to_owned(),
        RefactorError::NoTypeAnnotation => "there is no annotation to replace".to_owned(),
        RefactorError::NotRemovable => "that declaration cannot be deleted".to_owned(),
        RefactorError::IdTooLong => "the symbol's id exceeds the library's limit".to_owned(),
        other => format!("a reason this example predates: {other}"),
    }
}

/// The offset of a declaration's *name*, given the keyword and a space in front
/// of it.
///
/// `declaration_of("fn luminance", …) `is the point of this helper: searching
/// for `"luminance"` alone finds the mention in `demo.wgsl`'s header comment,
/// 500 bytes before the declaration, and every call in this module then answers
/// about nothing.
fn declaration_of(keyword_and_name: &str, source: &str) -> u32 {
    let start = source.find(keyword_and_name).unwrap_or_default();
    let past_keyword = keyword_and_name.find(' ').map_or(0, |space| space + 1);
    u32::try_from(start + past_keyword).unwrap_or_default()
}

/// A range and the text in it, or the word for not having one.
fn describe(source: &str, range: Option<ByteRange>) -> String {
    match range {
        Some(range) => format!(
            "{:>3}..{:<4}{:?}",
            range.start,
            range.end,
            elide(slice(source, range))
        ),
        None => "None".to_owned(),
    }
}

/// `source[range]`, without the panic — a range from one source used against
/// another is exactly the mistake this example is about.
fn slice(source: &str, range: ByteRange) -> &str {
    source
        .get(range.start as usize..range.end as usize)
        .unwrap_or("<not in this source>")
}

/// The whole declaration is 91 bytes; a table wants the first line of it.
fn elide(text: &str) -> String {
    let first = text.lines().next().unwrap_or_default();
    if first.len() == text.len() {
        first.to_owned()
    } else {
        format!("{first} …")
    }
}

/// The identifier starting at `offset`, so a printed offset can be checked.
fn word_at(source: &str, offset: u32) -> &str {
    let rest = source.get(offset as usize..).unwrap_or_default();
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    rest.get(..end).unwrap_or_default()
}

/// The line `offset` falls on, trimmed — a byte range the reader cannot see
/// resolved is not illuminating.
fn line_containing(source: &str, offset: u32) -> &str {
    let offset = offset as usize;
    let start = source
        .get(..offset)
        .and_then(|before| before.rfind('\n').map(|index| index + 1))
        .unwrap_or_default();
    let end = source
        .get(offset..)
        .and_then(|after| after.find('\n').map(|index| offset + index))
        .unwrap_or(source.len());
    source.get(start..end).unwrap_or_default().trim()
}

/// `1 reference`, `2 references` — a report that says "1 references" reads as a
/// bug in the report.
fn plural(count: usize, noun: &str) -> String {
    if count == 1 {
        format!("{count} {noun}")
    } else {
        format!("{count} {noun}s")
    }
}

/// A section rule, so four sections of output read as four sections.
fn heading(title: &str) {
    println!("\n{title}");
    println!("{}", "-".repeat(title.chars().count()));
}
