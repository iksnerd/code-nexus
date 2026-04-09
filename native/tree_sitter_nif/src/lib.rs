use rustler::NifResult;
use serde::Serialize;
use std::collections::HashMap;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unsupported_language
    }
}

#[derive(Serialize)]
struct AstNode {
    kind: String,
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
    text: String,
    children: Vec<AstNode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    fields: HashMap<String, String>,
}

fn get_language(lang: &str) -> Option<tree_sitter::Language> {
    match lang {
        "javascript" | "js" | "jsx" => Some(tree_sitter_javascript::LANGUAGE.into()),
        "typescript" | "ts" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "tsx" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        "python" | "py" => Some(tree_sitter_python::LANGUAGE.into()),
        "go" => Some(tree_sitter_go::LANGUAGE.into()),
        "rust" | "rs" => Some(tree_sitter_rust::LANGUAGE.into()),
        "java" => Some(tree_sitter_java::LANGUAGE.into()),
        "elixir" | "ex" => Some(tree_sitter_elixir::LANGUAGE.into()),
        _ => None,
    }
}

fn node_to_ast(node: tree_sitter::Node, source: &[u8], depth: usize) -> AstNode {
    let text = if node.child_count() == 0 || depth > 25 {
        node.utf8_text(source).unwrap_or("").to_string()
    } else {
        String::new()
    };

    // Extract the "name" field if present (common across languages)
    let name = node
        .child_by_field_name("name")
        .and_then(|n| n.utf8_text(source).ok())
        .map(|s| s.to_string());

    let mut fields = HashMap::new();

    // Extract common field names
    for field in &["parameters", "body", "return_type", "type", "value", "superclass"] {
        if let Some(child) = node.child_by_field_name(field) {
            if child.child_count() == 0 {
                if let Ok(t) = child.utf8_text(source) {
                    fields.insert(field.to_string(), t.to_string());
                }
            }
        }
    }

    let children = if depth < 25 {
        let mut cursor = node.walk();
        let mut children = Vec::new();
        for child in node.children(&mut cursor) {
            if is_significant_node(&child, depth) {
                children.push(node_to_ast(child, source, depth + 1));
            }
        }
        children
    } else {
        Vec::new()
    };

    AstNode {
        kind: node.kind().to_string(),
        start_row: node.start_position().row,
        start_col: node.start_position().column,
        end_row: node.end_position().row,
        end_col: node.end_position().column,
        text,
        children,
        name,
        fields,
    }
}

fn is_significant_node(node: &tree_sitter::Node, depth: usize) -> bool {
    let kind = node.kind();

    // At extreme depths, only allow declarations and calls — skip structural/block nodes
    if depth > 20 {
        return kind.contains("function")
            || kind.contains("method")
            || kind.contains("class")
            || kind.contains("declaration")
            || kind.contains("definition")
            || kind == "call_expression"
            || kind == "new_expression"
            || kind == "identifier"
            || kind == "property_identifier"
            || kind == "member_expression"
            || kind == "selector_expression"
            || kind == "field_identifier"
            || kind == "argument_list";
    }

    // Declarations and definitions
    kind.contains("function")
        || kind.contains("method")
        || kind.contains("class")
        || kind.contains("module")
        || kind.contains("interface")
        || kind.contains("struct")
        || kind.contains("impl")
        || kind.contains("def")
        || kind.contains("declaration")
        || kind.contains("definition")
        || kind.contains("import")
        || kind.contains("export")
        || kind.contains("use")
        || kind.contains("require")
        // Calls and expressions (needed for call graph extraction)
        || kind == "call_expression"
        || kind == "new_expression"
        || kind == "member_expression"
        // JSX component usage (treat renders as outgoing call edges)
        || kind == "jsx_element"
        || kind == "jsx_self_closing_element"
        || kind == "jsx_opening_element"
        // Parenthesized expressions wrap JSX returns: return (<Button />)
        || kind == "parenthesized_expression"
        || kind == "identifier"
        || kind == "property_identifier"
        // Blocks and statements (needed to reach nested calls)
        || kind == "statement_block"
        || kind == "expression_statement"
        || kind == "return_statement"
        || kind == "if_statement"
        || kind == "for_statement"
        || kind == "for_in_statement"
        || kind == "while_statement"
        || kind == "try_statement"
        || kind == "catch_clause"
        || kind == "switch_statement"
        || kind == "switch_case"
        // Variable assignments (const x = foo())
        || kind == "lexical_declaration"
        || kind == "variable_declaration"
        || kind == "variable_declarator"
        || kind == "assignment_expression"
        || kind == "augmented_assignment_expression"
        // Await/yield
        || kind == "await_expression"
        || kind == "yield_expression"
        // Arrow functions and callbacks
        || kind == "arrow_function"
        || kind == "arguments"
        // Structural
        || kind == "program"
        || kind == "source_file"
        || kind == "module_definition"
        || kind == "assignment"
        || kind == "call"
        // Import internals (needed to extract import source paths)
        || kind == "import_clause"
        || kind == "named_imports"
        || kind == "import_specifier"
        || kind == "string"
        || kind == "string_fragment"
        || kind == "template_string"
        // Python-specific
        || kind == "argument_list"
        || kind == "keyword_argument"
        || kind == "attribute"
        || kind == "decorated_definition"
        || kind == "decorator"
        // Go-specific (blocks and statements — needed to reach calls inside function bodies)
        || kind == "block"
        || kind == "var_declaration"
        || kind == "var_spec"
        || kind == "const_declaration"
        || kind == "const_spec"
        || kind == "assignment_statement"
        || kind == "if_statement"
        || kind == "for_statement"
        || kind == "range_clause"
        || kind == "switch_statement"
        || kind == "type_switch_statement"
        || kind == "expression_switch_statement"
        || kind == "select_statement"
        || kind == "communication_case"
        || kind == "expression_case"
        || kind == "default_case"
        || kind == "go_statement"
        || kind == "defer_statement"
        || kind == "return_statement"
        || kind == "expression_list"
        // Go-specific (identifiers and types)
        || kind == "selector_expression"
        || kind == "field_identifier"
        || kind == "type_identifier"
        || kind == "pointer_type"
        || kind == "parameter_declaration"
        || kind == "package_clause"
        || kind == "package_identifier"
        || kind == "interpreted_string_literal"
        || kind == "import_spec"
        || kind == "import_spec_list"
        || kind == "type_spec"
        || kind == "field_declaration"
        || kind == "field_declaration_list"
        || kind == "method_spec"
        || kind == "method_spec_list"
        || kind == "short_var_declaration"
        || kind == "composite_literal"
        || kind == "lexical_binding"
}

#[rustler::nif(schedule = "DirtyCpu")]
fn parse(language: String, source: String) -> NifResult<(rustler::Atom, String)> {
    let lang = match get_language(&language) {
        Some(l) => l,
        None => return Ok((atoms::error(), "unsupported_language".to_string())),
    };

    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&lang).map_err(|e| {
        rustler::Error::Term(Box::new(format!("Failed to set language: {}", e)))
    })?;

    let tree = parser
        .parse(&source, None)
        .ok_or_else(|| rustler::Error::Term(Box::new("Parse failed".to_string())))?;

    let root = tree.root_node();
    let ast = node_to_ast(root, source.as_bytes(), 0);

    let json = serde_json::to_string(&ast).map_err(|e| {
        rustler::Error::Term(Box::new(format!("JSON serialization failed: {}", e)))
    })?;

    Ok((atoms::ok(), json))
}

rustler::init!("Elixir.ElixirNexus.TreeSitterParser.Native");
