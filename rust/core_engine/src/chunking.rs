/// Split `text` into windows of at most `max_chars` characters where each
/// window starts `max_chars - overlap` characters after the previous one.
///
/// Adjacent windows share exactly `overlap` characters. Returns an empty
/// vector for empty input. Requires `max_chars > overlap`; otherwise returns
/// an empty vector.
pub fn split_text(text: &str, max_chars: usize, overlap: usize) -> Vec<String> {
    if max_chars == 0 || max_chars <= overlap {
        return Vec::new();
    }
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() {
        return Vec::new();
    }
    let step = max_chars - overlap;
    let mut out = Vec::new();
    let mut start = 0usize;
    loop {
        let end = (start + max_chars).min(chars.len());
        out.push(chars[start..end].iter().collect());
        if end == chars.len() {
            break;
        }
        start += step;
    }
    out
}

/// Join chunks produced by `split_text`, removing the shared `overlap`
/// characters from the head of each following chunk.
pub fn join_chunks(chunks: &[String], overlap: usize) -> String {
    let mut out = String::new();
    for chunk in chunks {
        if out.is_empty() {
            out.push_str(chunk);
        } else {
            out.push_str(strip_overlap(&out, chunk, overlap));
        }
    }
    out
}

/// Return `next` without its first `overlap` characters when those characters
/// equal the last `overlap` characters of `prev`. Otherwise return `next` unchanged.
///
/// Matching is exact and fixed-length on purpose: a shorter or fuzzy match
/// would delete legitimate repeated characters (e.g. "的" + "的").
fn strip_overlap<'a>(prev: &str, next: &'a str, overlap: usize) -> &'a str {
    if overlap == 0 {
        return next;
    }
    let tail: Vec<char> = prev.chars().rev().take(overlap).collect::<Vec<_>>().into_iter().rev().collect();
    if tail.len() != overlap {
        return next;
    }
    if !next.chars().take(overlap).eq(tail.iter().copied()) {
        return next;
    }
    match next.char_indices().nth(overlap) {
        Some((byte_idx, _)) => &next[byte_idx..],
        None => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(n: usize) -> String {
        "會議記錄第一段內容測試".chars().cycle().take(n).collect()
    }

    #[test]
    fn roundtrip_reconstructs_original_text() {
        for n in [1, 19, 20, 21, 100, 999, 1000, 1234] {
            let text = sample(n);
            let chunks = split_text(&text, 100, 20);
            assert_eq!(join_chunks(&chunks, 20), text, "length {n}");
        }
    }

    #[test]
    fn adjacent_chunks_share_exact_overlap() {
        let text = sample(250);
        let chunks = split_text(&text, 100, 20);
        assert!(chunks.len() > 1);
        for w in chunks.windows(2) {
            let tail: String = w[0].chars().rev().take(20).collect::<Vec<_>>().into_iter().rev().collect();
            let head: String = w[1].chars().take(20).collect();
            assert_eq!(tail, head);
        }
    }

    #[test]
    fn does_not_drop_legitimate_repeats() {
        // Chunks that do NOT come from split_text must not be trimmed.
        let chunks = vec!["你好的".to_string(), "的確如此".to_string()];
        assert_eq!(join_chunks(&chunks, 20), "你好的的確如此");
    }

    #[test]
    fn invalid_parameters_yield_no_chunks() {
        assert!(split_text("abc", 10, 10).is_empty());
        assert!(split_text("", 10, 2).is_empty());
    }
}
