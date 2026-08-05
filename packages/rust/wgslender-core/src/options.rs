//! Minification options.

use serde::Serialize;

/// Overrides for wgslender's minification defaults.
///
/// Every field is an override that is absent by default, so
/// `MinifyOptions::default()` means *no overrides — wgslender's own defaults
/// apply*, not *everything off*. That is exactly what an empty options object
/// means on the wire, and it is why this configuration struct derives `Default`
/// at all: [`minify_with`](crate::minify_with) with the default options
/// produces the same bytes as [`minify`](crate::minify).
///
/// The struct is `#[non_exhaustive]`, so downstream code builds it with the
/// chaining setters rather than a struct literal.
///
/// # Examples
///
/// ```
/// use wgslender_core::MinifyOptions;
///
/// let options = MinifyOptions::default()
///     .minify_whitespace(true)
///     .minify_identifiers(false)
///     .keep_names(["main"]);
/// ```
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct MinifyOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    minify_whitespace: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    minify_identifiers: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    minify_syntax: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tree_shaking: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mangle_external_bindings: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    preserve_uniform_struct_types: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    keep_names: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sort_declarations: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scope_local_rename: Option<bool>,
}

/// Generates the boolean setters, each with its own compiling example, so the
/// nine of them cannot drift apart.
macro_rules! bool_setters {
    ($($field:ident => $summary:literal),* $(,)?) => {
        impl MinifyOptions {
            $(
                #[doc = $summary]
                #[doc = ""]
                #[doc = "Absent by default, leaving wgslender's own default in place."]
                #[doc = ""]
                #[doc = "# Examples"]
                #[doc = ""]
                #[doc = "```"]
                #[doc = "use wgslender_core::MinifyOptions;"]
                #[doc = ""]
                #[doc = concat!(
                    "let options = MinifyOptions::default().",
                    stringify!($field),
                    "(true);",
                )]
                #[doc = "```"]
                #[must_use]
                pub fn $field(mut self, enabled: bool) -> Self {
                    self.$field = Some(enabled);
                    self
                }
            )*
        }
    };
}

bool_setters! {
    minify_whitespace => "Strips whitespace and comments.",
    minify_identifiers => "Renames identifiers to short names.",
    minify_syntax => "Rewrites syntax into shorter equivalent forms.",
    tree_shaking => "Drops declarations no entry point can reach.",
    mangle_external_bindings => "Renames `@group`/`@binding` variables too, changing the API a host program binds against.",
    preserve_uniform_struct_types => "Keeps the type names of uniform structs intact.",
    sort_declarations => "Groups similar declarations together, which compresses better.",
    scope_local_rename => "Reuses the same short names across sibling scopes, which compresses better.",
}

impl MinifyOptions {
    /// Identifiers that must never be renamed.
    ///
    /// Replaces any previously set list.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::MinifyOptions;
    ///
    /// let options = MinifyOptions::default().keep_names(["main", "luminance"]);
    /// ```
    #[must_use]
    pub fn keep_names<I, S>(mut self, names: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.keep_names = Some(names.into_iter().map(Into::into).collect());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::MinifyOptions;

    #[test]
    fn default_options_serialize_to_an_empty_object() {
        let Ok(json) = serde_json::to_string(&MinifyOptions::default()) else {
            panic!("default options must serialize")
        };
        assert_eq!(json, "{}");
    }

    #[test]
    fn set_options_serialize_to_camel_case_keys() {
        let options = MinifyOptions::default()
            .minify_whitespace(true)
            .tree_shaking(false)
            .keep_names(["main"]);
        let Ok(json) = serde_json::to_string(&options) else {
            panic!("options must serialize")
        };
        assert_eq!(
            json,
            r#"{"minifyWhitespace":true,"treeShaking":false,"keepNames":["main"]}"#
        );
    }
}
