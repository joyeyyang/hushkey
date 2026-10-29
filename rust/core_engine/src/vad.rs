/// Pick a cut index near `target` where the signal is quietest.
///
/// Scans non-overlapping `frame`-sample windows within `target ± search`
/// and returns the centre of the window with the lowest mean energy. The
/// first minimum wins on ties. The result is always in `(0, samples.len()]`
/// provided `samples.len() >= target + search`.
pub fn choose_cut(samples: &[f32], target: usize, search: usize, frame: usize) -> usize {
    let len = samples.len();
    let target = target.min(len);
    let frame = frame.max(1);
    let lo = target.saturating_sub(search).max(0);
    let hi = target.saturating_add(search).min(len);

    let mut best_energy = f32::INFINITY;
    let mut best_cut = target;
    let mut start = lo;
    while start + frame <= hi {
        let e = mean_energy(&samples[start..start + frame]);
        if e < best_energy {
            best_energy = e;
            best_cut = start + frame / 2;
        }
        start += frame;
    }
    best_cut.clamp(1, len.max(1))
}

fn mean_energy(window: &[f32]) -> f32 {
    window.iter().map(|x| x * x).sum::<f32>() / window.len() as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cuts_inside_silence_gap() {
        // Loud everywhere except samples [1000, 1200) which are silent.
        let mut s = vec![0.5f32; 3000];
        for x in &mut s[1000..1200] {
            *x = 0.0;
        }
        let cut = choose_cut(&s, 1100, 500, 100);
        assert!((1000..=1200).contains(&cut), "cut {cut} not in silent gap");
    }

    #[test]
    fn cut_is_within_bounds_when_window_is_clamped() {
        let s = vec![0.1f32; 500];
        let cut = choose_cut(&s, 400, 300, 100);
        assert!(cut >= 1 && cut <= s.len());
    }
}
