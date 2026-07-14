use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use codex_code_mode_protocol::CellId;
use codex_code_mode_protocol::CodeModeNestedToolCall;
use codex_code_mode_protocol::CodeModeSession;
use codex_code_mode_protocol::CodeModeSessionDelegate;
use codex_code_mode_protocol::CodeModeSessionProvider;
use codex_code_mode_protocol::CodeModeSessionProviderFuture;
use codex_code_mode_protocol::CodeModeSessionResultFuture;
use codex_code_mode_protocol::ExecuteRequest;
use codex_code_mode_protocol::FunctionCallOutputContentItem;
use codex_code_mode_protocol::NotificationFuture;
use codex_code_mode_protocol::RuntimeResponse;
use codex_code_mode_protocol::StartedCell;
use codex_code_mode_protocol::ToolDefinition;
use codex_code_mode_protocol::ToolInvocationFuture;
use codex_code_mode_protocol::WaitOutcome;
use codex_code_mode_protocol::WaitRequest;
use serde_json::Value as JsonValue;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

const MOBILE_UNSUPPORTED_MESSAGE: &str =
    "mobile code mode supports shell execution through exec_command only";

pub struct NoopCodeModeSessionDelegate;

impl CodeModeSessionDelegate for NoopCodeModeSessionDelegate {
    fn invoke_tool<'a>(
        &'a self,
        _invocation: CodeModeNestedToolCall,
        cancellation_token: CancellationToken,
    ) -> ToolInvocationFuture<'a> {
        Box::pin(async move {
            cancellation_token.cancelled().await;
            Err("code mode nested tools are unavailable".to_string())
        })
    }

    fn notify<'a>(
        &'a self,
        _call_id: String,
        _cell_id: CellId,
        _text: String,
        _cancellation_token: CancellationToken,
    ) -> NotificationFuture<'a> {
        Box::pin(async { Ok(()) })
    }

    fn cell_closed(&self, _cell_id: &CellId) {}
}

#[derive(Default)]
pub struct InProcessCodeModeSessionProvider;

impl CodeModeSessionProvider for InProcessCodeModeSessionProvider {
    fn create_session<'a>(
        &'a self,
        delegate: Arc<dyn CodeModeSessionDelegate>,
    ) -> CodeModeSessionProviderFuture<'a> {
        Box::pin(async move {
            let session: Arc<dyn CodeModeSession> =
                Arc::new(InProcessCodeModeSession::with_delegate(delegate));
            Ok(session)
        })
    }
}

pub struct InProcessCodeModeSession {
    delegate: Arc<dyn CodeModeSessionDelegate>,
    next_cell_id: AtomicU64,
}

impl InProcessCodeModeSession {
    pub fn new() -> Self {
        Self::with_delegate(Arc::new(NoopCodeModeSessionDelegate))
    }

    pub fn with_delegate(delegate: Arc<dyn CodeModeSessionDelegate>) -> Self {
        Self {
            delegate,
            next_cell_id: AtomicU64::new(1),
        }
    }

    pub async fn execute(&self, request: ExecuteRequest) -> Result<StartedCell, String> {
        let cell_id = CellId::new(
            self.next_cell_id
                .fetch_add(1, Ordering::Relaxed)
                .to_string(),
        );
        let response_cell_id = cell_id.clone();
        let delegate = Arc::clone(&self.delegate);
        let (response_tx, response_rx) = oneshot::channel();
        let initial_cell = cell_id.clone();
        tokio::spawn(async move {
            let response = execute_mobile_shell_cell(delegate, initial_cell, request).await;
            let _ = response_tx.send(response);
        });
        Ok(StartedCell::from_result_receiver(
            response_cell_id,
            response_rx,
        ))
    }

    pub async fn wait(&self, request: WaitRequest) -> Result<WaitOutcome, String> {
        Ok(WaitOutcome::MissingCell(RuntimeResponse::Result {
            cell_id: request.cell_id,
            content_items: Vec::new(),
            error_text: Some("mobile code mode cells finish during exec".to_string()),
        }))
    }

    pub async fn terminate(&self, cell_id: CellId) -> Result<WaitOutcome, String> {
        Ok(WaitOutcome::MissingCell(RuntimeResponse::Terminated {
            cell_id,
            content_items: Vec::new(),
        }))
    }

    pub async fn shutdown(&self) -> Result<(), String> {
        Ok(())
    }
}

impl Default for InProcessCodeModeSession {
    fn default() -> Self {
        Self::new()
    }
}

impl CodeModeSession for InProcessCodeModeSession {
    fn execute<'a>(
        &'a self,
        request: ExecuteRequest,
    ) -> CodeModeSessionResultFuture<'a, StartedCell> {
        Box::pin(InProcessCodeModeSession::execute(self, request))
    }

    fn wait<'a>(&'a self, request: WaitRequest) -> CodeModeSessionResultFuture<'a, WaitOutcome> {
        Box::pin(InProcessCodeModeSession::wait(self, request))
    }

    fn terminate<'a>(&'a self, cell_id: CellId) -> CodeModeSessionResultFuture<'a, WaitOutcome> {
        Box::pin(InProcessCodeModeSession::terminate(self, cell_id))
    }

    fn shutdown<'a>(&'a self) -> CodeModeSessionResultFuture<'a, ()> {
        Box::pin(InProcessCodeModeSession::shutdown(self))
    }
}

async fn execute_mobile_shell_cell(
    delegate: Arc<dyn CodeModeSessionDelegate>,
    cell_id: CellId,
    request: ExecuteRequest,
) -> Result<RuntimeResponse, String> {
    let Some((tool, command)) = mobile_exec_invocation(&request.enabled_tools, &request.source)
    else {
        return Ok(error_response(cell_id, MOBILE_UNSUPPORTED_MESSAGE));
    };

    let input = match tool.tool_name.name.as_str() {
        "exec_command" => serde_json::json!({ "cmd": command }),
        "shell_command" => serde_json::json!({ "command": command }),
        _ => {
            return Ok(error_response(
                cell_id,
                "mobile code mode could not find a supported shell tool",
            ));
        }
    };

    let result = delegate
        .invoke_tool(
            CodeModeNestedToolCall {
                cell_id: cell_id.clone(),
                runtime_tool_call_id: format!("{}-mobile-shell", request.tool_call_id),
                tool_name: tool.tool_name,
                tool_kind: tool.kind,
                input: Some(input),
            },
            CancellationToken::new(),
        )
        .await;

    match result {
        Ok(value) => Ok(RuntimeResponse::Result {
            cell_id,
            content_items: vec![FunctionCallOutputContentItem::InputText {
                text: render_tool_result(value),
            }],
            error_text: None,
        }),
        Err(error) => Ok(error_response(cell_id, &error)),
    }
}

fn mobile_exec_invocation(
    enabled_tools: &[ToolDefinition],
    source: &str,
) -> Option<(ToolDefinition, String)> {
    let tool = enabled_tools
        .iter()
        .find(|tool| tool.tool_name.name == "exec_command")
        .or_else(|| {
            enabled_tools
                .iter()
                .find(|tool| tool.tool_name.name == "shell_command")
        })?
        .clone();

    let command = extract_command_literal(source).unwrap_or_else(|| source.trim().to_string());
    if command.trim().is_empty() {
        None
    } else {
        Some((tool, command))
    }
}

fn extract_command_literal(source: &str) -> Option<String> {
    extract_keyed_string(source, "cmd").or_else(|| extract_keyed_string(source, "command"))
}

fn extract_keyed_string(source: &str, key: &str) -> Option<String> {
    let bytes = source.as_bytes();
    let mut index = 0;
    while let Some(relative) = source.get(index..)?.find(key) {
        let key_start = index + relative;
        if !is_identifier_boundary(bytes, key_start, key.len()) {
            index = key_start + key.len();
            continue;
        }
        let mut cursor = key_start + key.len();
        cursor = skip_ws(bytes, cursor);
        if bytes.get(cursor) != Some(&b':') {
            index = cursor;
            continue;
        }
        cursor = skip_ws(bytes, cursor + 1);
        let quote = *bytes.get(cursor)?;
        if quote != b'\'' && quote != b'"' && quote != b'`' {
            index = cursor;
            continue;
        }
        return parse_quoted(source, cursor, quote);
    }
    None
}

fn is_identifier_boundary(bytes: &[u8], start: usize, len: usize) -> bool {
    let before_ok = start == 0 || !is_identifier_char(bytes[start - 1]);
    let after = start + len;
    let after_ok = after >= bytes.len() || !is_identifier_char(bytes[after]);
    before_ok && after_ok
}

fn is_identifier_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$'
}

fn skip_ws(bytes: &[u8], mut cursor: usize) -> usize {
    while matches!(bytes.get(cursor), Some(b' ' | b'\n' | b'\r' | b'\t')) {
        cursor += 1;
    }
    cursor
}

fn parse_quoted(source: &str, quote_index: usize, quote: u8) -> Option<String> {
    let bytes = source.as_bytes();
    let mut cursor = quote_index + 1;
    let mut value = String::new();
    while cursor < bytes.len() {
        let byte = bytes[cursor];
        if byte == quote {
            return Some(value);
        }
        if byte == b'\\' {
            cursor += 1;
            let escaped = *bytes.get(cursor)?;
            value.push(match escaped {
                b'n' => '\n',
                b'r' => '\r',
                b't' => '\t',
                b'\\' => '\\',
                b'\'' => '\'',
                b'"' => '"',
                b'`' => '`',
                other => other as char,
            });
        } else {
            value.push(byte as char);
        }
        cursor += 1;
    }
    None
}

fn render_tool_result(value: JsonValue) -> String {
    if let Some(output) = value.get("output").and_then(JsonValue::as_str) {
        return output.to_string();
    }
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    serde_json::to_string_pretty(&value).unwrap_or_else(|err| {
        format!("mobile code mode executed shell command but could not format output: {err}")
    })
}

fn error_response(cell_id: CellId, message: &str) -> RuntimeResponse {
    RuntimeResponse::Result {
        cell_id,
        content_items: Vec::new(),
        error_text: Some(message.to_string()),
    }
}
