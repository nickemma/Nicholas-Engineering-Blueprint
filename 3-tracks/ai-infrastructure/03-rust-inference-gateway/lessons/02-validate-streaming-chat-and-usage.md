# 02 Validate streaming chat and usage

> A Rust inference gateway · Week 1

## The problem

An SSE event can contain a role update, content, usage, or a terminal marker. Treating every transport read as output makes first-content measurements wrong and can count an unfinished response as a success.

## The mental model

~~~text
request → allowlisted chat payload
SSE data → role or content delta → matching usage → [DONE]
~~~

## The pattern

Keep a separate semantic state machine after the framing layer. This chat profile uses one choice, text deltas, and one usage frame. Count the first nonempty content separately. Compare upstream prompt usage with the tokenizer result and bound completion usage by the requested maximum. A completion must include content, matching usage, and a terminal event.

## Build it

### Expose the wire contract

Keep the framing and chat validation in different modules.

Create or update `src/lib.rs` as shown.

<!-- file: src/lib.rs -->
~~~rust
pub mod protocol;
pub mod sse;
~~~

### Build and validate the profile

Allowlist the upstream request. Normalize each validated JSON chunk for SSE output. The model usage field supplies generated token counts.

Create or update `src/protocol.rs` as shown.

<!-- file: src/protocol.rs -->
~~~rust
//! The bounded single-choice chat profile shared with the serving lab.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::sse::Frame;

pub const MAX_CONTEXT: u32 = 4096;
pub const MAX_OUTPUT: u32 = 128;
pub const MAX_INPUT: usize = 16 * 1024;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub messages: Vec<Message>,
    pub max_tokens: u32,
    pub stream: bool,
}

impl Request {
    pub fn valid(&self) -> bool {
        self.stream
            && (1..=MAX_OUTPUT).contains(&self.max_tokens)
            && (1..=16).contains(&self.messages.len())
            && self.messages.iter().all(|message| {
                matches!(message.role.as_str(), "user" | "assistant" | "system")
                    && !message.content.is_empty()
                    && message.content.len() <= 4096
            })
    }

    pub fn upstream(&self) -> Value {
        json!({
            "messages": self.messages,
            "max_tokens": self.max_tokens,
            "stream": true,
            "temperature": 0,
            "cache_prompt": false,
            "stream_options": {"include_usage": true},
        })
    }
}

#[derive(Deserialize)]
struct Chunk {
    choices: Vec<Choice>,
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Choice {
    delta: Delta,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Delta {
    #[serde(rename = "role")]
    _role: Option<String>,
    content: Option<String>,
}

#[derive(Deserialize)]
struct Usage {
    prompt_tokens: u32,
    completion_tokens: u32,
}

pub enum Delivered {
    Item { json: String, first_content: bool },
    Done,
}

pub struct Completion {
    prompt_tokens: u32,
    max_tokens: u32,
    content: bool,
    usage: bool,
}

impl Completion {
    pub fn new(prompt_tokens: u32, max_tokens: u32) -> Self {
        Self {
            prompt_tokens,
            max_tokens,
            content: false,
            usage: false,
        }
    }

    pub fn accept(&mut self, frame: Frame) -> Result<Delivered, &'static str> {
        if !frame.event.is_empty() && frame.event != "message" {
            return Err("unexpected upstream event");
        }
        if frame.data == "[DONE]" {
            return if self.content && self.usage {
                Ok(Delivered::Done)
            } else {
                Err("missing content or usage")
            };
        }
        let raw: Value = serde_json::from_str(&frame.data).map_err(|_| "invalid chat chunk")?;
        if raw.get("error").is_some() {
            return Err("upstream error event");
        }
        let chunk: Chunk =
            serde_json::from_value(raw.clone()).map_err(|_| "invalid chat fields")?;
        if chunk.choices.len() > 1 || self.usage {
            return Err("invalid choice or chunk after usage");
        }
        let has_content = chunk.choices.first().is_some_and(|choice| {
            choice
                .delta
                .content
                .as_ref()
                .is_some_and(|text| !text.is_empty())
        });
        if let Some(usage) = chunk.usage {
            if !chunk.choices.is_empty()
                || usage.prompt_tokens != self.prompt_tokens
                || usage.completion_tokens > self.max_tokens
            {
                return Err("usage disagrees with reservation");
            }
            self.usage = true;
        }
        let first_content = has_content && !self.content;
        self.content |= has_content;
        Ok(Delivered::Item {
            json: raw.to_string(),
            first_content,
        })
    }
}
~~~

## Check it

~~~bash
cargo check --locked
~~~

<!-- run: cargo check --locked -->

An upstream JSON frame must fit the profile before it is relayed. In the live test, a role event arrives before the first content and the usage mismatch never earns a terminal marker.
