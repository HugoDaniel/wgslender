//! Rule-based linting, and the autofixes some rules carry.

use core::fmt;
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize, Serializer, ser::SerializeTuple};
use wgslender_sys::{wgslender_lint_c, wgslender_lint_fix_c};

/// A rule's options object. Re-exported so callers need not depend on
/// `serde_json` themselves.
pub use serde_json::Value;

use crate::buffer::{LibBuffer, checked_len, take_json};
use crate::error::Error;
use crate::validate::Diagnostic;

/// A shareable rule set, the equivalent of an `extends` entry in
/// `wgslender.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Pack {
    /// The default set: rules that catch likely mistakes.
    Recommended,
    /// Formatting and naming conventions.
    Style,
    /// Rules about shader cost.
    Performance,
    /// Rules about running on more backends.
    Portability,
    /// Rules that make a shader minify better.
    Minify,
    /// Everything, at error severity.
    Strict,
}

impl Pack {
    /// The name the library knows this pack by.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::Pack;
    ///
    /// assert_eq!(Pack::Recommended.as_str(), "@wgslender/recommended");
    /// ```
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Recommended => "@wgslender/recommended",
            Self::Style => "@wgslender/style",
            Self::Performance => "@wgslender/performance",
            Self::Portability => "@wgslender/portability",
            Self::Minify => "@wgslender/minify",
            Self::Strict => "@wgslender/strict",
        }
    }
}

impl fmt::Display for Pack {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl Serialize for Pack {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

/// What one rule should do.
///
/// The `*With` variants carry that rule's own options object, which the wire
/// spells as a `["warn", { … }]` pair.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum RuleSetting {
    /// Do not run the rule.
    Off,
    /// Run it, reporting at warning severity.
    Warn,
    /// Run it, reporting at error severity.
    Error,
    /// Warn, with rule-specific options.
    WarnWith(Value),
    /// Error, with rule-specific options.
    ErrorWith(Value),
}

impl RuleSetting {
    /// The severity word this setting serializes with.
    fn severity(&self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Warn | Self::WarnWith(_) => "warn",
            Self::Error | Self::ErrorWith(_) => "error",
        }
    }
}

impl Serialize for RuleSetting {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Off | Self::Warn | Self::Error => serializer.serialize_str(self.severity()),
            Self::WarnWith(options) | Self::ErrorWith(options) => {
                let mut pair = serializer.serialize_tuple(2)?;
                pair.serialize_element(self.severity())?;
                pair.serialize_element(options)?;
                pair.end()
            }
        }
    }
}

/// Which rules to run, and how loudly.
///
/// `Default` is the *empty* config, which runs **no rules at all** — unlike
/// [`MinifyOptions`](crate::MinifyOptions), whose default means "the library's
/// own defaults". Start from [`Pack::Recommended`] to get wgslender's opinion:
///
/// ```
/// use wgslender_core::{LintConfig, Pack, RuleSetting};
///
/// let config = LintConfig::default()
///     .extend(Pack::Recommended)
///     .rule("no-magic-numbers", RuleSetting::Off);
/// ```
///
/// Later settings win over earlier ones, and over anything a pack said.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct LintConfig {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    extends: Vec<Pack>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    rules: BTreeMap<String, RuleSetting>,
    #[serde(skip_serializing_if = "Option::is_none")]
    report_unused_disable_directives: Option<bool>,
}

impl LintConfig {
    /// Add a shareable pack.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::{LintConfig, Pack, lint};
    ///
    /// // The empty config runs nothing, so a pack is what gives the linter an
    /// // opinion at all.
    /// let source = "fn unused_helper(x: f32) -> f32 { return x; }\n";
    /// assert_eq!(lint(source, &LintConfig::default())?.warning_count, 0);
    ///
    /// let config = LintConfig::default().extend(Pack::Recommended);
    /// assert!(lint(source, &config)?.warning_count > 0);
    /// # Ok::<(), wgslender_core::Error>(())
    /// ```
    #[must_use]
    pub fn extend(mut self, pack: Pack) -> Self {
        self.extends.push(pack);
        self
    }

    /// Set one rule, overriding whatever a pack said about it.
    ///
    /// An id no rule answers to is **silently ignored** — the library does not
    /// report unknown rule names, so a typo here reads as a rule that never
    /// fires.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::{LintConfig, Pack, RuleSetting};
    ///
    /// let config = LintConfig::default()
    ///     .extend(Pack::Recommended)
    ///     .rule("no-unused-vars", RuleSetting::Off);
    /// # let _ = config;
    /// ```
    #[must_use]
    pub fn rule(mut self, id: impl Into<String>, setting: RuleSetting) -> Self {
        self.rules.insert(id.into(), setting);
        self
    }

    /// Report `wgslender-disable` comments that suppress nothing.
    ///
    /// # Examples
    ///
    /// ```
    /// use wgslender_core::{LintConfig, Pack, lint};
    ///
    /// // Nothing in here self-assigns, so the directive silences nothing.
    /// let source = "\
    /// // wgslender-disable no-self-assign
    ///
    /// @compute @workgroup_size(1)
    /// fn main() {}
    /// ";
    ///
    /// let config = LintConfig::default()
    ///     .extend(Pack::Recommended)
    ///     .report_unused_disable_directives(true);
    /// let report = lint(source, &config)?;
    /// assert!(
    ///     report.diagnostics.iter().any(|d| d.code.as_deref() == Some("W0209")),
    ///     "the dead directive is the finding"
    /// );
    /// # Ok::<(), wgslender_core::Error>(())
    /// ```
    #[must_use]
    pub fn report_unused_disable_directives(mut self, enabled: bool) -> Self {
        self.report_unused_disable_directives = Some(enabled);
        self
    }

    /// This config as the JSON the C ABI reads.
    fn to_wire(&self) -> Result<String, Error> {
        Ok(serde_json::to_string(self)?)
    }
}

/// What [`lint`] found.
///
/// The counts and the diagnostics array do not line up, and that is the
/// library's shape rather than an oversight here: `error_count` covers both the
/// validator's errors and the linter's, while `warning_count` covers **only**
/// the linter's — even though `diagnostics` also carries the validator's
/// warnings. Count severities in `diagnostics` yourself if you need a total.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct LintReport {
    /// Validator errors plus lint errors.
    pub error_count: u32,
    /// Lint warnings only.
    pub warning_count: u32,
    /// How many diagnostics carry an autofix [`lint_fix`] can apply.
    pub fixable_count: u32,
    /// Every diagnostic, validator's first and then the linter's.
    pub diagnostics: Vec<Diagnostic>,
}

/// What [`lint_fix`] produced.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct LintFixOutcome {
    /// The source with every available autofix applied.
    pub fixed_source: String,
    /// The report for the source **as it was handed in** — not for
    /// `fixed_source`. Run [`lint`] on `fixed_source` to see what is left.
    pub report: LintReport,
}

/// Run the configured rules over a shader.
///
/// Rule violations are not a Rust `Err`: they come back as `Ok` with a report.
/// The error type is reserved for the FFI call itself going wrong.
///
/// # Errors
///
/// [`Error::SourceTooLarge`] if the source or the serialized config does not
/// fit in a `u32`; [`Error::Internal`] if the library could not allocate its
/// report; [`Error::Wire`] if the report is not the JSON this crate expects.
///
/// # Examples
///
/// ```
/// use wgslender_core::{LintConfig, RuleSetting, lint};
///
/// let source = "fn helper() -> u32 { return 1u; }";
/// let config = LintConfig::default().rule("no-unused-vars", RuleSetting::Warn);
///
/// let report = lint(source, &config)?;
/// assert_eq!(report.warning_count, 1);
/// assert_eq!(report.diagnostics[0].code.as_deref(), Some("W0001"));
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn lint(source: &str, config: &LintConfig) -> Result<LintReport, Error> {
    let source_len = checked_len(source)?;
    let config = config.to_wire()?;
    let config_len = checked_len(&config)?;
    // SAFETY: `source` and `config` are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result =
        unsafe { wgslender_lint_c(source.as_ptr(), source_len, config.as_ptr(), config_len) };
    // SAFETY: `json_ptr`/`json_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    unsafe { take_json(result.json_ptr, result.json_len) }
}

/// Lint a shader and apply every autofix in one pass.
///
/// Rules whose diagnostics carry no fix are reported and left alone, so the
/// returned source can still lint dirty.
///
/// # Errors
///
/// As [`lint`], plus [`Error::InvalidUtf8`] if the rewritten source is not
/// UTF-8.
///
/// # Examples
///
/// ```
/// use wgslender_core::{LintConfig, RuleSetting, lint_fix};
///
/// let source = "@group(0) @binding(0) var<storage, read_write> out: array<u32>;\n\
///               @compute @workgroup_size(1)\n\
///               fn main() { var x = 1u; out[0] = x; }";
/// let config = LintConfig::default().rule("prefer-let-over-var", RuleSetting::Warn);
///
/// let outcome = lint_fix(source, &config)?;
/// assert!(outcome.fixed_source.contains("let x = 1u"));
/// assert_eq!(outcome.report.fixable_count, 1, "the report describes the input");
/// # Ok::<(), wgslender_core::Error>(())
/// ```
pub fn lint_fix(source: &str, config: &LintConfig) -> Result<LintFixOutcome, Error> {
    let source_len = checked_len(source)?;
    let config = config.to_wire()?;
    let config_len = checked_len(&config)?;
    // SAFETY: `source` and `config` are each valid for reads of their own
    // length for the whole call, and the library only reads through them.
    let result =
        unsafe { wgslender_lint_fix_c(source.as_ptr(), source_len, config.as_ptr(), config_len) };

    // Adopt the rewritten source before anything can fail, so that an
    // unparseable report still frees it.
    // SAFETY: `fixed_ptr`/`fixed_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    let fixed = unsafe { LibBuffer::adopt(result.fixed_ptr, result.fixed_len) };
    // SAFETY: `json_ptr`/`json_len` are a different buffer from the same
    // result, likewise adopted exactly once.
    let report: LintReport = unsafe { take_json(result.json_ptr, result.json_len) }?;

    let Some(fixed) = fixed else {
        return Err(Error::Internal);
    };
    Ok(LintFixOutcome {
        fixed_source: fixed.into_string()?,
        report,
    })
}

#[cfg(test)]
mod tests {
    use super::{LintConfig, Pack, RuleSetting};

    fn wire(config: &LintConfig) -> String {
        match config.to_wire() {
            Ok(json) => json,
            Err(err) => panic!("a lint config must serialize: {err}"),
        }
    }

    /// An empty config is `{}` on the wire, which the library reads as "run no
    /// rules".
    #[test]
    fn default_serializes_to_an_empty_object() {
        assert_eq!(wire(&LintConfig::default()), "{}");
    }

    #[test]
    fn packs_and_rules_use_their_wire_spelling() {
        let config = LintConfig::default()
            .extend(Pack::Recommended)
            .extend(Pack::Strict)
            .rule("no-magic-numbers", RuleSetting::Off)
            .rule("no-shadow", RuleSetting::Error)
            .report_unused_disable_directives(true);
        assert_eq!(
            wire(&config),
            r#"{"extends":["@wgslender/recommended","@wgslender/strict"],"rules":{"no-magic-numbers":"off","no-shadow":"error"},"reportUnusedDisableDirectives":true}"#
        );
    }

    /// Rule options travel as the wire's severity/options pair.
    #[test]
    fn rule_options_serialize_as_a_pair() {
        let config = LintConfig::default().rule(
            "max-params",
            RuleSetting::WarnWith(serde_json::json!({ "max": 4 })),
        );
        assert_eq!(
            wire(&config),
            r#"{"rules":{"max-params":["warn",{"max":4}]}}"#
        );
    }

    /// Setting the same rule twice keeps the last word.
    #[test]
    fn a_later_setting_replaces_an_earlier_one() {
        let config = LintConfig::default()
            .rule("no-shadow", RuleSetting::Warn)
            .rule("no-shadow", RuleSetting::Off);
        assert_eq!(wire(&config), r#"{"rules":{"no-shadow":"off"}}"#);
    }
}
