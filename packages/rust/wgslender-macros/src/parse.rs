//! The macro's argument list: a path, then `key = value` pairs.

use std::mem;

use syn::parse::{Parse, ParseStream};
use syn::{Ident, LitBool, LitStr, Token, bracketed};
use wgslender_core::{MinifyOptions, Strictness};

/// Whether the embedded text is minified or copied through as written.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Minification {
    /// Run the minifier, with whatever options the invocation set.
    Minify,
    /// Embed the file's bytes.
    Verbatim,
}

/// What the macro puts in the binary.
///
/// Chosen by which entry point was called, and consulted twice: it picks the
/// minification defaults here, and the shape of the expansion in
/// [`crate::expand`].
#[derive(Debug, Clone, Copy)]
pub(crate) enum Embedding {
    /// The shader text, as a `&'static str`.
    Text,
    /// A deflate stream that inflates back to it, as a `CompressedWgsl`.
    #[cfg(feature = "compress")]
    Compressed,
    /// A module of constants and structs, with the text inside it.
    Module,
}

/// Whether the generated structs carry bytemuck's derives.
///
/// Only [`Embedding::Module`] generates structs, so only that form accepts the
/// key that chooses this.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Bytemuck {
    /// Add `#[derive(Pod, Zeroable)]`, which needs the caller to depend on
    /// bytemuck themselves.
    Derive,
    /// Leave the structs deriving what everything else derives.
    Skip,
}

impl Embedding {
    /// Where this embedding starts before the invocation's own options apply.
    ///
    /// Compressing defaults `sort_declarations` and `scope_local_rename` on:
    /// both exist to group similar text together, which is worth nothing to a
    /// reader and a good deal to DEFLATE. Either can still be turned back off
    /// by naming it.
    fn defaults(self) -> MinifyOptions {
        match self {
            Self::Text | Self::Module => MinifyOptions::default(),
            #[cfg(feature = "compress")]
            Self::Compressed => MinifyOptions::default()
                .sort_declarations(true)
                .scope_local_rename(true),
        }
    }

    /// Whether this form generates the structs `bytemuck` would derive on.
    fn generates_structs(self) -> bool {
        matches!(self, Self::Module)
    }
}

/// Whether the shader is type-checked before it is embedded.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Checking {
    /// Reject the shader, at compile time, if the library rejects it.
    Validate,
    /// Embed whatever is in the file.
    Skip,
}

/// One `include_wgsl!` invocation, parsed.
///
/// No `Debug`: deriving it would mean pulling in syn's `extra-traits`, and this
/// crate has nothing to print it to.
pub(crate) struct Invocation {
    /// Kept as the literal rather than as a `String`: every error this macro
    /// raises is about the file, and the literal is what the squiggle should sit
    /// under.
    pub(crate) path: LitStr,
    /// Whether to type-check first.
    pub(crate) checking: Checking,
    /// How harshly, when checking.
    pub(crate) strictness: Strictness,
    /// Whether to minify.
    pub(crate) minification: Minification,
    /// How, when minifying.
    pub(crate) options: MinifyOptions,
    /// What the expansion hands back.
    pub(crate) embedding: Embedding,
    /// Whether generated structs carry bytemuck's derives. Meaningless unless
    /// the embedding generates structs, which is why the key is refused
    /// elsewhere rather than ignored.
    pub(crate) bytemuck: Bytemuck,
}

/// Generates the setter lookup and the list of names the error message offers,
/// from one list — so "valid options are …" cannot name a key that nothing
/// handles, nor omit one that something does.
macro_rules! passthrough_options {
    ($($key:ident),* $(,)?) => {
        /// Every [`MinifyOptions`] boolean, spelled as the macro accepts it.
        const PASSTHROUGH_KEYS: &[&str] = &[$(stringify!($key)),*];

        /// The setter for a key, or `None` if it is not one of ours.
        ///
        /// Returning the setter rather than applying it lets the caller find out
        /// whether a key exists *before* parsing its value, so an unknown key is
        /// reported as an unknown key rather than as a bad value.
        fn passthrough_setter(key: &str) -> Option<fn(MinifyOptions, bool) -> MinifyOptions> {
            match key {
                $(stringify!($key) => Some(|options, value| options.$key(value)),)*
                _ => None,
            }
        }
    };
}

passthrough_options! {
    minify_whitespace,
    minify_identifiers,
    minify_syntax,
    tree_shaking,
    mangle_external_bindings,
    preserve_uniform_struct_types,
    sort_declarations,
    scope_local_rename,
}

/// The keys handled here rather than handed to [`MinifyOptions`].
const OWN_KEYS: &[&str] = &["minify", "validate", "strict", "keep_names"];

/// The keys only a form that generates Rust types can mean anything by.
const MODULE_KEYS: &[&str] = &["bytemuck"];

/// What a key needs the macro to be doing for it to mean anything.
///
/// Tracked so that an invocation which contradicts itself — tuning a
/// minification it turned off — is rejected instead of half-applied.
#[derive(Debug, Clone, Copy)]
enum Depends {
    /// Only means something while minifying.
    OnMinification,
    /// Only means something while validating.
    OnValidation,
}

impl Invocation {
    /// Reads `("path" [, key = value]*)`.
    ///
    /// Takes the embedding rather than implementing [`Parse`], because the same
    /// grammar means slightly different things depending on which macro is
    /// being expanded, and [`Parse`] has nowhere to say which.
    pub(crate) fn parse(input: ParseStream, embedding: Embedding) -> syn::Result<Self> {
        let mut invocation = Self {
            path: input.parse()?,
            checking: Checking::Validate,
            strictness: Strictness::Default,
            minification: Minification::Minify,
            options: embedding.defaults(),
            embedding,
            bytemuck: Bytemuck::Skip,
        };
        let mut dependents: Vec<(Ident, Depends)> = Vec::new();

        while !input.is_empty() {
            input.parse::<Token![,]>()?;
            if input.is_empty() {
                break; // A trailing comma, which is not an option.
            }
            let key: Ident = input.parse()?;
            input.parse::<Token![=]>()?;
            set(&mut invocation, &mut dependents, key, input)?;
        }

        invocation.reject_contradictions(&dependents)?;
        Ok(invocation)
    }

    /// Rejects keys that cannot mean anything given the rest of the invocation.
    fn reject_contradictions(&self, dependents: &[(Ident, Depends)]) -> syn::Result<()> {
        for (key, depends) in dependents {
            let disabled_by = match (depends, self.minification, self.checking) {
                (Depends::OnMinification, Minification::Verbatim, _) => "minify = false",
                (Depends::OnValidation, _, Checking::Skip) => "validate = false",
                _ => continue,
            };
            return Err(syn::Error::new(
                key.span(),
                format!("`{key}` has no effect together with `{disabled_by}`"),
            ));
        }
        Ok(())
    }
}

/// Applies one `key = value` pair, consuming the value from `input`.
fn set(
    invocation: &mut Invocation,
    dependents: &mut Vec<(Ident, Depends)>,
    key: Ident,
    input: ParseStream,
) -> syn::Result<()> {
    match key.to_string().as_str() {
        "minify" => {
            invocation.minification = if bool_value(input)? {
                Minification::Minify
            } else {
                Minification::Verbatim
            };
        }
        "validate" => {
            invocation.checking = if bool_value(input)? {
                Checking::Validate
            } else {
                Checking::Skip
            };
        }
        "strict" => {
            invocation.strictness = if bool_value(input)? {
                Strictness::Strict
            } else {
                Strictness::Default
            };
            dependents.push((key, Depends::OnValidation));
        }
        "keep_names" => {
            let names = name_list(input)?;
            invocation.options = mem::take(&mut invocation.options).keep_names(names);
            dependents.push((key, Depends::OnMinification));
        }
        "bytemuck" if invocation.embedding.generates_structs() => {
            invocation.bytemuck = if bool_value(input)? {
                Bytemuck::Derive
            } else {
                Bytemuck::Skip
            };
        }
        name => {
            let Some(setter) = passthrough_setter(name) else {
                return Err(unknown_option(&key, invocation.embedding));
            };
            let value = bool_value(input)?;
            invocation.options = setter(mem::take(&mut invocation.options), value);
            dependents.push((key, Depends::OnMinification));
        }
    }
    Ok(())
}

/// A `true` or `false` literal.
fn bool_value(input: ParseStream) -> syn::Result<bool> {
    Ok(input.parse::<LitBool>()?.value)
}

/// A `["one", "two"]` list of string literals.
fn name_list(input: ParseStream) -> syn::Result<Vec<String>> {
    let names;
    bracketed!(names in input);
    let names = names.parse_terminated(<LitStr as Parse>::parse, Token![,])?;
    Ok(names.iter().map(LitStr::value).collect())
}

/// Names the key that does not exist, then the ones that do.
///
/// A key that exists for another form is worth its own sentence: `bytemuck`
/// under `include_wgsl!` is not a typo, it is a key aimed at structs that macro
/// does not generate, and saying "unknown option" would send the author looking
/// for a spelling mistake.
fn unknown_option(key: &Ident, embedding: Embedding) -> syn::Error {
    if MODULE_KEYS.contains(&key.to_string().as_str()) {
        return syn::Error::new(
            key.span(),
            format!(
                "`{key}` names derives for the structs a macro generates, and this one generates \
                 none; it is `wgsl_module!`'s option",
            ),
        );
    }

    let mut valid = OWN_KEYS.to_vec();
    if embedding.generates_structs() {
        valid.extend_from_slice(MODULE_KEYS);
    }
    valid.extend_from_slice(PASSTHROUGH_KEYS);
    syn::Error::new(
        key.span(),
        format!(
            "unknown option `{key}`; valid options are {}",
            valid.join(", ")
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::{MODULE_KEYS, OWN_KEYS, PASSTHROUGH_KEYS, passthrough_setter};

    /// The lists that make up the "valid options are …" message must not
    /// overlap, or the message would offer the same key twice.
    #[test]
    fn the_key_sets_are_disjoint() {
        for key in OWN_KEYS {
            assert!(
                !PASSTHROUGH_KEYS.contains(key),
                "`{key}` is claimed by both key sets"
            );
        }
        for key in MODULE_KEYS {
            assert!(
                !OWN_KEYS.contains(key) && !PASSTHROUGH_KEYS.contains(key),
                "`{key}` is claimed by more than one key set"
            );
        }
    }

    /// Every key the message offers as a passthrough has a setter behind it.
    #[test]
    fn every_offered_passthrough_key_resolves() {
        for key in PASSTHROUGH_KEYS {
            assert!(
                passthrough_setter(key).is_some(),
                "`{key}` is offered but not handled"
            );
        }
    }

    #[test]
    fn an_unknown_key_has_no_setter() {
        assert!(passthrough_setter("minify_idents").is_none());
    }
}
