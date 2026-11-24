# 01 Keep storage operations inside a tenant namespace

> Integrity and encryption · Week 1 · Builds on lesson 00

## The problem

Two tenants both use the key `job`. Adding a tenant field to a response cannot protect them if both writes still use the same physical key.

## The mental model

Think of each tenant as owning one contiguous interval in the ordered byte keyspace. Prefix the logical key with the tenant ID length and bytes. For an unbounded tenant scan, the exclusive end is the bytewise successor of the prefix.

## The pattern

The service creates a storage handle using the tenant from a verified authorization decision. The handle scopes each operation at the storage boundary. A pinned read carries the tenant scope as well as a storage sequence.

## Build it

### Step 1 — Draw the composite keys

Sketch the bytes for tenant `a` and tenant `aÿ`. Give both an empty user key and an identical nonempty key.

<details>
<summary>Hint</summary>

A length prefix keeps a tenant ID separate from any leading bytes in its user keys.

</details>

### Step 2 — Compute both range endpoints

Write the successor of a prefix ending in `ff`. Then map an explicit higher or lower logical endpoint to the same tenant.

<details>
<summary>Hint</summary>

Carry past trailing `ff` bytes, increment the preceding byte, and truncate there.

</details>

### Step 3 — Bind every operation to the handle

Wrap put, delete, get, scan, and snapshot reads. Refuse a pin created for a different tenant.

<details>
<summary>Hint</summary>

Apply the prefix once, at the call into the raw storage engine. Strip it only for returned rows.

</details>

<details>
<summary>Implementation</summary>

Create `storage/src/namespace.rs`.

<!-- file: storage/src/namespace.rs -->
~~~rust
use std::io;

use crate::{Row, Snapshot, Store};

#[derive(Clone, Eq, PartialEq)]
pub struct Tenant(Vec<u8>);

impl Tenant {
    /// The caller supplies the tenant from an already authorized request.
    pub fn from_authorized(id: &[u8]) -> io::Result<Self> {
        if id.is_empty() || id.len() > 128 {
            return Err(input("tenant identifier must have 1–128 bytes"));
        }
        let mut prefix = (id.len() as u16).to_be_bytes().to_vec();
        prefix.extend(id);
        Ok(Self(prefix))
    }

    pub fn handle<'a>(&self, store: &'a mut Store) -> Namespace<'a> {
        Namespace {
            tenant: self.clone(),
            store,
        }
    }

    pub(crate) fn physical(&self, key: &[u8]) -> io::Result<Vec<u8>> {
        if key.len() > 1024 - self.0.len() {
            return Err(input("tenant key exceeds the storage key limit"));
        }
        let mut physical = self.0.clone();
        physical.extend(key);
        Ok(physical)
    }

    fn upper(&self) -> Vec<u8> {
        let mut upper = self.0.clone();
        // A length <= 128 supplies a byte below 0xff in the prefix.
        let i = upper.iter().rposition(|&byte| byte != 0xff).unwrap();
        upper[i] += 1;
        upper.truncate(i + 1);
        upper
    }
}

fn input(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

pub struct TenantSnapshot {
    tenant: Tenant,
    snapshot: Snapshot,
}

pub struct Namespace<'a> {
    tenant: Tenant,
    store: &'a mut Store,
}

impl Namespace<'_> {
    pub fn put(&mut self, key: &[u8], value: &[u8]) -> io::Result<u64> {
        self.store.put(&self.tenant.physical(key)?, value)
    }

    pub fn delete(&mut self, key: &[u8]) -> io::Result<u64> {
        self.store.delete(&self.tenant.physical(key)?)
    }

    pub fn get(&self, key: &[u8]) -> io::Result<Option<Vec<u8>>> {
        self.store.get(&self.tenant.physical(key)?)
    }

    pub fn snapshot(&self) -> TenantSnapshot {
        TenantSnapshot {
            tenant: self.tenant.clone(),
            snapshot: self.store.snapshot(),
        }
    }

    fn check_pin<'a>(&self, pin: &'a TenantSnapshot) -> io::Result<&'a Snapshot> {
        if pin.tenant != self.tenant {
            return Err(input("snapshot belongs to another tenant"));
        }
        Ok(&pin.snapshot)
    }

    pub fn get_at(&self, key: &[u8], pin: &TenantSnapshot) -> io::Result<Option<Vec<u8>>> {
        self.store
            .get_at(&self.tenant.physical(key)?, self.check_pin(pin)?)
    }

    pub fn scan(
        &self,
        start: Option<&[u8]>,
        end: Option<&[u8]>,
        pin: Option<&TenantSnapshot>,
    ) -> io::Result<Vec<Row>> {
        let start = self.tenant.physical(start.unwrap_or_default())?;
        let end = match end {
            Some(key) => self.tenant.physical(key)?,
            None => self.tenant.upper(),
        };
        let rows = match pin {
            Some(pin) => self.store.scan_at(&start, &end, self.check_pin(pin)?)?,
            None => self.store.scan(&start, &end)?,
        };
        let prefix_len = self.tenant.0.len();
        Ok(rows
            .into_iter()
            .map(|(key, value)| (key[prefix_len..].to_vec(), value))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf};

    pub(super) struct Temp(pub PathBuf);

    impl Temp {
        pub(super) fn new(label: &str) -> io::Result<Self> {
            let path =
                std::env::temp_dir().join(format!("lsm-security-{label}-{}", std::process::id()));
            fs::create_dir(&path)?;
            Ok(Self(path))
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn tenant_scan_stays_inside_namespace() -> io::Result<()> {
        let directory = Temp::new("namespace")?;
        let a = Tenant::from_authorized(b"a\xff")?;
        let b = Tenant::from_authorized(b"b\x00")?;
        let c = Tenant::from_authorized(b"a")?;
        let mut db = Store::open(&directory.0)?;
        a.handle(&mut db).put(b"", b"empty-key")?;
        a.handle(&mut db).put(b"same", b"first")?;
        b.handle(&mut db).put(b"same", b"second")?;
        c.handle(&mut db).put(b"\xffsame", b"overlapping-prefix")?;
        a.handle(&mut db).put(b"\xff\xff", b"high")?;
        let pin = a.handle(&mut db).snapshot();
        a.handle(&mut db).delete(b"same")?;
        db.flush()?;
        db.compact()?;
        assert_eq!(
            a.handle(&mut db).get_at(b"same", &pin)?,
            Some(b"first".to_vec())
        );
        assert!(b.handle(&mut db).get_at(b"same", &pin).is_err());
        let all = a.handle(&mut db).scan(None, None, Some(&pin))?;
        assert_eq!(
            all,
            vec![
                (vec![], b"empty-key".to_vec()),
                (b"same".to_vec(), b"first".to_vec()),
                (b"\xff\xff".to_vec(), b"high".to_vec()),
            ],
            "tenant scan crossed the namespace boundary"
        );
        assert_eq!(
            a.handle(&mut db)
                .scan(Some(b"same"), Some(b"\xff\xff"), Some(&pin))?,
            vec![(b"same".to_vec(), b"first".to_vec())],
        );
        drop(db);
        let mut db = Store::open(&directory.0)?;
        assert_eq!(a.handle(&mut db).get(b"same")?, None);
        assert_eq!(b.handle(&mut db).get(b"same")?, Some(b"second".to_vec()));
        assert_eq!(a.handle(&mut db).scan(None, None, None)?.len(), 2);
        assert_eq!(b.handle(&mut db).scan(None, None, None)?.len(), 1);
        assert_eq!(b.handle(&mut db).delete(b"absent")?, 7);
        println!(
            "tenant point reads, binary ranges, deletion, and pins stayed scoped across reopen"
        );
        Ok(())
    }
}
~~~

Find these regions in `storage/src/lib.rs` in order.

<!-- edit: storage/src/lib.rs -->
~~~rust
mod fault;
mod manifest;
mod merge;
mod snapshot;
mod table;
~~~

Replace the selected lines with this block.

~~~rust
mod fault;
mod manifest;
mod merge;
mod namespace;
mod snapshot;
mod table;
~~~

<!-- edit: storage/src/lib.rs -->
~~~rust
use table::Table;

pub use compact::Compaction;
pub use snapshot::Snapshot;

#[derive(Debug, Default, Eq, PartialEq)]
~~~

Replace the selected lines with this block.

~~~rust
use table::Table;

pub use compact::Compaction;
pub use namespace::{Namespace, Tenant, TenantSnapshot};
pub use snapshot::Snapshot;

#[derive(Debug, Default, Eq, PartialEq)]
~~~

</details>

### Step 4 — Compare namespaces through reopen

Walk the fixture in the test. Predict the result of each point read and decide which rows belong in the full tenant scan and its narrowed version.

<details>
<summary>Hint</summary>

One tenant has a prefix ending in `ff` and a logical key made entirely of high bytes.

</details>

## Check it

~~~bash
cargo test --locked --quiet --manifest-path storage/Cargo.toml --lib tenant_scan_stays_inside_namespace -- --nocapture
~~~

<!-- run: cargo test --locked --quiet --manifest-path storage/Cargo.toml --lib tenant_scan_stays_inside_namespace -- --nocapture -->

The run kept point reads, binary ranges, deletes, and snapshot reads scoped through reopen.

## If it goes wrong

If a full scan includes a neighboring tenant, compare the actual end key with the successor of the encoded prefix. If a pinned read is refused, trace which tenant and store created the handle.
