//! A few recently used values by key, for what is made per frame from the frame's own
//! textures (wrappers of Vulkan images, bind groups): the frames of a pool come back in
//! turn, so each is made once instead of every frame.

/// Values of up to `cap` keys, the most recently used first.
pub(crate) struct Lru<K, V> {
    cap: usize,
    items: Vec<(K, V)>,
}

impl<K: PartialEq, V> Lru<K, V> {
    // Only the Vulkan path uses new/get/insert outside tests.
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub fn new(cap: usize) -> Self {
        Lru { cap, items: Vec::new() }
    }

    /// The value of `key`, made by `make` when absent (dropping the least recently used
    /// beyond the capacity). The flag says whether it was made.
    pub fn get_or_make<E>(&mut self, key: K, make: impl FnOnce(&K) -> Result<V, E>) -> Result<(&V, bool), E> {
        let made = match self.items.iter().position(|(k, _)| *k == key) {
            Some(i) => {
                let item = self.items.remove(i);
                self.items.insert(0, item);
                false
            }
            None => {
                let value = make(&key)?;
                self.items.insert(0, (key, value));
                self.items.truncate(self.cap.max(1));
                true
            }
        };
        Ok((&self.items[0].1, made))
    }

    /// The value of `key`, now the most recently used.
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub fn get(&mut self, key: &K) -> Option<&V> {
        let i = self.items.iter().position(|(k, _)| k == key)?;
        let item = self.items.remove(i);
        self.items.insert(0, item);
        Some(&self.items[0].1)
    }

    /// Adds `value` as the most recently used, dropping the least recently used beyond
    /// the capacity. `key` must not be there yet.
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub fn insert(&mut self, key: K, value: V) {
        self.items.insert(0, (key, value));
        self.items.truncate(self.cap.max(1));
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.items.len()
    }
}

impl<K, V> Default for Lru<K, V> {
    fn default() -> Self {
        Lru { cap: FRAMES, items: Vec::new() }
    }
}

/// Entries per cache: more than the frames FFmpeg keeps in flight on one link.
pub(crate) const FRAMES: usize = 16;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_most_recent_keys() {
        let mut lru = Lru::new(2);
        let get = |lru: &mut Lru<u32, u32>, k| *lru.get_or_make(k, |&k| Ok::<_, ()>(k * 10)).unwrap().0;
        assert_eq!(get(&mut lru, 1), 10);
        assert_eq!(get(&mut lru, 2), 20);
        assert!(!lru.get_or_make(1, |_| Err(())).unwrap().1, "1 is kept");
        assert_eq!(get(&mut lru, 3), 30);
        assert_eq!(lru.len(), 2);
        assert!(lru.get_or_make(2, |_| Ok::<_, ()>(0)).unwrap().1, "2 was the least recently used");
    }
}
