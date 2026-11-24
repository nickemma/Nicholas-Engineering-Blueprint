# 01 Frame SSE across byte boundaries

> A Rust inference gateway · Week 1

## The problem

A model response can split a UTF-8 character, a line break, or an entire event across transport reads. A single read can also contain several events. Frame the byte stream before interpreting it as a chat completion.

## The mental model

~~~text
transport bytes → complete line → data fields plus event type → blank line dispatch
                       buffer ≤ 8 KiB      joined data ≤ 32 KiB
~~~

## The pattern

Accept LF, CR, and CRLF. Ignore a leading BOM and comment lines. Join repeated data fields with one newline. Carry state across chunks and return one event at a time. The lab rejects invalid UTF-8 and ignores reconnect fields. The HTTP request owns a single upstream generation. [SSE framing standard](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream)

## Build it

### Export the parser

Make the parser available to later modules.

Create or update `src/lib.rs` as shown.

<!-- file: src/lib.rs -->
~~~rust
pub mod sse;
~~~

### Recognize complete frames

Consume bytes through one event and leave the remaining slice to the next call. Bound lines and accumulated event data separately.

Create or update `src/sse.rs` as shown.

<!-- file: src/sse.rs -->
~~~rust
//! Bounded framing for the gateway's upstream SSE stream.

const MAX_LINE: usize = 8 * 1024;
const MAX_DATA: usize = 32 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub struct Frame {
    pub event: String,
    pub data: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    LineLimit,
    EventLimit,
    InvalidUtf8,
}

pub struct Decoder {
    line: Vec<u8>,
    data: String,
    event: String,
    saw_data: bool,
    skip_lf: bool,
    first_line: bool,
}

impl Default for Decoder {
    fn default() -> Self {
        Self {
            line: Vec::new(),
            data: String::new(),
            event: String::new(),
            saw_data: false,
            skip_lf: false,
            first_line: true,
        }
    }
}

impl Decoder {
    // Leave the remainder in input so the caller handles at most one event
    // at a time, even when one transport chunk contains many events.
    pub fn next(&mut self, input: &mut &[u8]) -> Result<Option<Frame>, FrameError> {
        while let Some((&byte, remainder)) = input.split_first() {
            *input = remainder;
            if std::mem::take(&mut self.skip_lf) && byte == b'\n' {
                continue;
            }
            if byte == b'\r' || byte == b'\n' {
                self.skip_lf = byte == b'\r';
                let event = self.end_line()?;
                self.line.clear();
                if event.is_some() {
                    return Ok(event);
                }
            } else {
                if self.line.len() == MAX_LINE {
                    return Err(FrameError::LineLimit);
                }
                self.line.push(byte);
            }
        }
        Ok(None)
    }

    fn end_line(&mut self) -> Result<Option<Frame>, FrameError> {
        let mut line = std::str::from_utf8(&self.line).map_err(|_| FrameError::InvalidUtf8)?;
        if std::mem::take(&mut self.first_line) {
            line = line.strip_prefix('\u{feff}').unwrap_or(line);
        }
        if line.is_empty() {
            let event = std::mem::take(&mut self.event);
            if !std::mem::take(&mut self.saw_data) {
                return Ok(None);
            }
            let data = std::mem::take(&mut self.data);
            return Ok(Some(Frame { event, data }));
        }
        let (field, value) = line.split_once(':').unwrap_or((line, ""));
        let value = value.strip_prefix(' ').unwrap_or(value);
        match field {
            "data" => {
                if self.data.len() + value.len() + usize::from(self.saw_data) > MAX_DATA {
                    return Err(FrameError::EventLimit);
                }
                if self.saw_data {
                    self.data.push('\n');
                }
                self.data.push_str(value);
                self.saw_data = true;
            }
            "event" => self.event = value.to_owned(),
            _ => {}
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_multiline_data_across_every_byte() {
        let input = "\u{feff}: hello\r\nevent: message\rdata: café\r\ndata: second\n\r";
        let mut decoder = Decoder::default();
        let mut found = Vec::new();
        for byte in input.as_bytes().chunks(1) {
            if let Some(frame) = decoder.next(&mut &*byte).unwrap() {
                found.push(frame);
            }
        }
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].event, "message");
        assert_eq!(
            found[0].data, "café\nsecond",
            "joined data must preserve LF"
        );
        println!("framing: split UTF-8, BOM, comments, and mixed line endings preserved data");
    }

    #[test]
    fn dispatches_one_complete_event_and_never_flushes_a_partial_one() {
        let mut decoder = Decoder::default();
        let mut input = b"data: a\n\ndata: b\n\ndata: unfinished\n".as_slice();
        assert_eq!(decoder.next(&mut input).unwrap().unwrap().data, "a");
        assert_eq!(decoder.next(&mut input).unwrap().unwrap().data, "b");
        assert!(decoder.next(&mut input).unwrap().is_none());
        assert!(input.is_empty());
    }

    #[test]
    fn rejects_malformed_utf8_and_both_buffer_overflows() {
        let mut decoder = Decoder::default();
        assert_eq!(
            decoder.next(&mut b"data: \xff\n".as_slice()),
            Err(FrameError::InvalidUtf8)
        );
        let mut decoder = Decoder::default();
        let line = vec![b'a'; MAX_LINE + 1];
        assert_eq!(
            decoder.next(&mut line.as_slice()),
            Err(FrameError::LineLimit)
        );
        let mut decoder = Decoder::default();
        let many = format!("data: {}\n", "a".repeat(6000)).repeat(6);
        assert_eq!(
            decoder.next(&mut many.as_bytes()),
            Err(FrameError::EventLimit)
        );
    }
}
~~~

## Check it

~~~bash
cargo test --locked sse::tests -- --nocapture
~~~

<!-- run: cargo test --locked sse::tests -- --nocapture -->

The byte-by-byte test preserves the newline and the accented character. A partial last frame yields no event. If a row appears twice around CRLF, inspect the parser state carried across calls.
