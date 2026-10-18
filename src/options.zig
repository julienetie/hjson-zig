//! Decoder / encoder options. Port of Hjson::DecoderOptions and
//! Hjson::EncoderOptions (defaults taken from hjson.h).

pub const DecoderOptions = struct {
    /// Keep all comments from the input and store them in the Value tree.
    comments: bool = true,
    /// Store all whitespace and comments so that line feeds and custom
    /// indentation are kept. Implies `comments = true`.
    whitespace_as_comments: bool = false,
    /// Fail with `error.SyntaxError` if a map contains duplicate keys.
    duplicate_key_exception: bool = false,
};

pub const EncoderOptions = struct {
    /// End of line, should be either "\n" or "\r\n".
    eol: []const u8 = "\n",
    /// Place braces on the same line as the key.
    braces_same_line: bool = true,
    /// Always place string values in double quotes and escape special chars.
    quote_always: bool = false,
    /// Always place keys in quotes.
    quote_keys: bool = false,
    /// Indent string.
    indent_by: []const u8 = "  ",
    /// Allow the -0 value (unlike ES6).
    allow_minus_zero: bool = false,
    /// Present in the C++ header but not used by the C++ encoder sources.
    /// Kept for API parity; currently has no effect.
    unknown_as_null: bool = false,
    /// Output a comma between elements. If true, strings are always quoted
    /// (overrides `quote_always`).
    separator: bool = false,
    /// If true, map keys are written in insertion order. If false, in
    /// alphabetical (byte-wise) key order.
    preserve_insertion_order: bool = true,
    /// Omit the braces around the root map.
    omit_root_braces: bool = false,
    /// Write comments, if any are stored in the Value tree.
    comments: bool = true,
};
