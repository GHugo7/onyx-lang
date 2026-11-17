//! Loads a program made of several files and links them into one `Program`.
//!
//! Each imported file is a module. Its top-level names are prefixed with the
//! module name (`add` in `utils.ox` becomes `utils.add`), and every reference
//! is rewritten accordingly, so the type checker and the code generators only
//! ever see one flat program with unique names.

use crate::ast::*;
use crate::checker::is_builtin;
use crate::diagnostics::{Diagnostic, SourceMap, Span};
use crate::parser;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

struct Module {
    /// Prefix for this module's names; empty for the entry file.
    name: String,
    items: Vec<Item>,
    /// Import alias -> module index.
    imports: HashMap<String, usize>,
    /// The folder of the file, to read what it embeds, and the same folder as
    /// messages name it.
    dir: PathBuf,
    shown_dir: PathBuf,
}

/// The top-level names of a module, before prefixing.
struct ModInfo {
    name: String,
    types: HashSet<String>,
    values: HashSet<String>,
}

struct Loader<'a> {
    sources: &'a mut SourceMap,
    modules: Vec<Module>,
    by_path: HashMap<PathBuf, usize>,
    /// Module indices, dependencies first.
    order: Vec<usize>,
    next_id: usize,
    used_names: HashSet<String>,
}

/// `path` without `.` and with the `..` that can be resolved resolved, as
/// the compiler written in Onyx does it (`join` in compiler/modules.ox). This
/// is how a file is named in messages: as seen from where the program was
/// started, like the user wrote it.
fn tidy(path: &Path) -> String {
    let text = path.to_string_lossy();
    let absolute = text.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in text.split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            if parts.last().is_some_and(|last| *last != "..") {
                parts.pop();
                continue;
            }
            if absolute {
                continue;
            }
        }
        parts.push(part);
    }
    let joined = parts.join("/");
    if absolute {
        format!("/{joined}")
    } else {
        joined
    }
}

/// Imports may leave out the `.ox` at the end.
fn with_ox(path: String) -> String {
    let name = path.rsplit('/').next().unwrap_or(&path);
    if name.len() > 3 && name.ends_with(".ox") {
        path
    } else {
        path + ".ox"
    }
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    chars.next().is_some_and(|c| c == '_' || c.is_alphabetic()) && chars.all(|c| c == '_' || c.is_alphanumeric())
}

/// Loads `entry` and everything it imports. On an unreadable entry file the
/// error has no source location, so it is returned as a plain message.
///
/// `prelude` is extra source appended to the program as is (the native
/// runtime); its byte range in `sources` is returned along with the program.
pub fn load(
    entry: &Path,
    sources: &mut SourceMap,
    prelude: Option<(&str, &str)>,
    companion: Option<&Path>,
) -> Result<(Program, Option<(usize, usize)>), Result<Vec<Diagnostic>, String>> {
    let text = std::fs::read_to_string(entry)
        .map_err(|e| Err(format!("cannot read `{}`: {e}", entry.display())))?;
    let canonical = std::fs::canonicalize(entry).unwrap_or_else(|_| entry.to_path_buf());
    let mut loader = Loader {
        sources,
        modules: Vec::new(),
        by_path: HashMap::new(),
        order: Vec::new(),
        next_id: 0,
        used_names: HashSet::new(),
    };
    let main = loader
        .load_file(canonical, entry.to_string_lossy().to_string(), String::new(), &text)
        .map_err(|d| Ok(vec![d]))?;
    // A test file (`name.test.ox`) is part of the file it tests: it sees
    // everything in it, private names included, without importing it.
    if let Some(path) = companion {
        let text = std::fs::read_to_string(path).map_err(|e| Err(format!("cannot read `{}`: {e}", path.display())))?;
        let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let dir = canonical.parent().map(Path::to_path_buf).unwrap_or_default();
        let shown_dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let (start, end) = loader.sources.add(path.to_string_lossy().to_string(), &text);
        let (program, next_id) =
            parser::parse(&loader.sources.text, start, end, loader.next_id).map_err(|d| Ok(vec![d]))?;
        loader.next_id = next_id;
        loader.absorb(main, dir, shown_dir, program).map_err(|d| Ok(vec![d]))?;
    }

    let infos: Vec<ModInfo> = loader.modules.iter().map(module_info).collect();
    let mut diags = Vec::new();
    let mut items = Vec::new();
    let order = loader.order.clone();
    for idx in order {
        let module = &mut loader.modules[idx];
        let mut resolver = Resolver {
            infos: &infos,
            me: idx,
            imports: &module.imports,
            dir: &module.dir,
            shown_dir: &module.shown_dir,
            scopes: Vec::new(),
            diags: &mut diags,
        };
        for item in &mut module.items {
            resolver.item(item);
        }
        let is_entry = infos[idx].name.is_empty();
        for item in module.items.drain(..) {
            match item {
                Item::Import { .. } => {}
                // Only the checks of the file being tested are run.
                Item::Check { .. } if !is_entry => {}
                other => items.push(other),
            }
        }
    }
    let mut prelude_range = None;
    if let Some((name, text)) = prelude {
        let (start, end) = loader.sources.add(name.to_string(), text);
        let (program, _) = parser::parse(&loader.sources.text, start, end, loader.next_id).map_err(|d| Ok(vec![d]))?;
        items.extend(program.items);
        prelude_range = Some((start, end));
    }
    if diags.is_empty() {
        Ok((Program { items }, prelude_range))
    } else {
        diags.sort_by_key(|d| d.span.start);
        Err(Ok(diags))
    }
}

fn module_info(module: &Module) -> ModInfo {
    let mut info = ModInfo { name: module.name.clone(), types: HashSet::new(), values: HashSet::new() };
    for item in &module.items {
        match item {
            Item::Fn(f) => {
                info.values.insert(f.name.clone());
            }
            Item::Struct(s) => {
                info.types.insert(s.name.clone());
            }
            Item::Interface(i) => {
                info.types.insert(i.name.clone());
            }
            Item::Enum(e) => {
                info.types.insert(e.name.clone());
            }
            Item::Global(Stmt { kind: StmtKind::Let { name, .. }, .. }) => {
                info.values.insert(name.clone());
            }
            _ => {}
        }
    }
    info
}

impl<'a> Loader<'a> {
    fn load_file(&mut self, canonical: PathBuf, display: String, name: String, text: &str) -> Result<usize, Diagnostic> {
        let shown_dir = Path::new(&display).parent().map(Path::to_path_buf).unwrap_or_default();
        let (start, end) = self.sources.add(display, text);
        let (program, next_id) = parser::parse(&self.sources.text, start, end, self.next_id)?;
        self.next_id = next_id;

        let idx = self.modules.len();
        let dir = canonical.parent().map(Path::to_path_buf).unwrap_or_default();
        self.by_path.insert(canonical, idx);
        self.modules.push(Module {
            name,
            items: Vec::new(),
            imports: HashMap::new(),
            dir: dir.clone(),
            shown_dir: shown_dir.clone(),
        });
        self.absorb(idx, dir, shown_dir, program)?;
        self.order.push(idx);
        Ok(idx)
    }

    /// Adds the items of a parsed file, found in `dir` (shown in messages as
    /// `shown_dir`), to module `idx`, loading what it imports.
    fn absorb(&mut self, idx: usize, dir: PathBuf, shown_dir: PathBuf, program: Program) -> Result<(), Diagnostic> {
        let mut imports: HashMap<String, usize> = std::mem::take(&mut self.modules[idx].imports);
        for item in &program.items {
            let Item::Import { path, alias, span } = item else { continue };
            let mut file = dir.join(path);
            if file.extension().is_none_or(|ext| ext != "ox") {
                file.as_mut_os_string().push(".ox");
            }
            let shown = with_ox(tidy(&shown_dir.join(path)));
            let stem = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let alias = alias.clone().unwrap_or_else(|| stem.clone());
            if !is_identifier(&alias) {
                return Err(Diagnostic::new("E0402", format!("`{alias}` cannot be used as a module name"), *span)
                    .help(format!("give it a name: `import \"{path}\" as my_module`")));
            }
            if imports.contains_key(&alias) {
                return Err(Diagnostic::new("E0402", format!("the name `{alias}` is already used by another import"), *span)
                    .help(format!("rename one of them: `import \"{path}\" as other_name`")));
            }
            let not_found = |why: String| {
                Diagnostic::new("E0400", format!("cannot find module \"{path}\""), *span)
                    .label(why)
                    .help(format!("imports are relative to the importing file; looked for `{shown}`"))
            };
            let canonical = std::fs::canonicalize(&file).map_err(|_| not_found("no such file".into()))?;
            let target = match self.by_path.get(&canonical) {
                Some(&target) => target,
                None => {
                    let text = std::fs::read_to_string(&canonical).map_err(|e| not_found(e.to_string()))?;
                    // Module prefixes must be unique even when two files share a name.
                    let base: String = stem.chars().map(|c| if c == '_' || c.is_alphanumeric() { c } else { '_' }).collect();
                    let mut name = base.clone();
                    let mut n = 2;
                    while !self.used_names.insert(name.clone()) {
                        name = format!("{base}~{n}");
                        n += 1;
                    }
                    self.load_file(canonical, shown.clone(), name, &text)?
                }
            };
            imports.insert(alias, target);
        }

        // A module's own names would hide an import of the same name.
        for item in &program.items {
            let (name, span) = match item {
                Item::Fn(f) => (&f.name, f.name_span),
                Item::Global(Stmt { kind: StmtKind::Let { name, name_span, .. }, .. }) => (name, *name_span),
                _ => continue,
            };
            if imports.contains_key(name) {
                return Err(Diagnostic::new("E0402", format!("`{name}` is also the name of an imported module"), span)
                    .help("rename it, or import the module under another name with `as`"));
            }
        }

        self.modules[idx].items.extend(program.items);
        self.modules[idx].imports = imports;
        Ok(())
    }
}

struct Resolver<'a> {
    infos: &'a [ModInfo],
    me: usize,
    imports: &'a HashMap<String, usize>,
    dir: &'a Path,
    shown_dir: &'a Path,
    /// Local variables in scope; they hide top-level names and imports.
    scopes: Vec<HashSet<String>>,
    diags: &'a mut Vec<Diagnostic>,
}

impl<'a> Resolver<'a> {
    fn qualify(&self, module: usize, name: &str) -> String {
        let prefix = &self.infos[module].name;
        if prefix.is_empty() {
            name.to_string()
        } else {
            format!("{prefix}.{name}")
        }
    }

    fn is_local(&self, name: &str) -> bool {
        self.scopes.iter().any(|s| s.contains(name))
    }

    fn declare(&mut self, name: &str) {
        if let Some(scope) = self.scopes.last_mut() {
            scope.insert(name.to_string());
        }
    }

    fn check_private(&mut self, module: usize, name: &str, span: Span) {
        if module != self.me && name.starts_with('_') {
            self.diags.push(
                Diagnostic::new("E0401", format!("`{name}` is private to its module"), span)
                    .help("names starting with `_` can only be used in the file that defines them"),
            );
        }
    }

    /// `embed("file")`: the text of the file, read when the program is
    /// compiled, as a string literal. The path is relative to the file that
    /// contains the call, like an import.
    fn embed(&mut self, args: &[Expr], span: Span) -> Option<ExprKind> {
        let path = match args {
            [Expr { kind: ExprKind::Str(parts), .. }] => match parts.as_slice() {
                [StrPart::Lit(path)] => path.clone(),
                _ => String::new(),
            },
            _ => String::new(),
        };
        if path.is_empty() {
            self.diags.push(
                Diagnostic::new("E0104", "`embed` takes the path of a file, written as a plain string", span)
                    .help("for example `embed(\"data/words.txt\")`"),
            );
            return None;
        }
        let shown = tidy(&self.shown_dir.join(&path));
        match std::fs::read_to_string(self.dir.join(&path)) {
            Ok(text) => Some(ExprKind::Str(vec![StrPart::Lit(text)])),
            Err(_) => {
                self.diags.push(
                    Diagnostic::new("E0400", format!("cannot read the file \"{path}\""), span)
                        .label("no such file")
                        .help(format!("the path is relative to the file that contains `embed`; looked for `{shown}`")),
                );
                None
            }
        }
    }

    /// Resolves a type or struct name, possibly written `module.Name`.
    fn type_name(&mut self, name: &mut String, span: Span) {
        if let Some((alias, item)) = name.split_once('.') {
            let (alias, item) = (alias.to_string(), item.to_string());
            match self.imports.get(&alias) {
                Some(&module) if self.infos[module].types.contains(&item) => {
                    self.check_private(module, &item, span);
                    *name = self.qualify(module, &item);
                }
                Some(_) => self.diags.push(Diagnostic::new("E0401", format!("module `{alias}` has no type `{item}`"), span)),
                None => self.diags.push(
                    Diagnostic::new("E0401", format!("unknown module `{alias}`"), span)
                        .help(format!("add `import \"{alias}\"` at the top of the file")),
                ),
            }
        } else if self.infos[self.me].types.contains(name.as_str()) {
            *name = self.qualify(self.me, name);
        }
    }

    fn type_expr(&mut self, t: &mut TypeExpr) {
        match &mut t.kind {
            TypeKind::Named(name) => self.type_name(name, t.span),
            TypeKind::List(elem) | TypeKind::Chan(elem) | TypeKind::Weak(elem) => self.type_expr(elem),
            TypeKind::Map(k, v) => {
                self.type_expr(k);
                self.type_expr(v);
            }
            TypeKind::Fn { params, ret, .. } => {
                for p in params {
                    self.type_expr(p);
                }
                if let Some(ret) = ret {
                    self.type_expr(ret);
                }
            }
        }
    }

    fn item(&mut self, item: &mut Item) {
        let prefixed = !self.infos[self.me].name.is_empty();
        match item {
            Item::Fn(f) => {
                if prefixed && is_builtin(&f.name) {
                    self.diags.push(Diagnostic::new(
                        "E0103",
                        format!("`{}` is a built-in function and cannot be redefined", f.name),
                        f.name_span,
                    ));
                }
                f.name = self.qualify(self.me, &f.name);
                self.function(f);
            }
            Item::Struct(s) => {
                s.name = self.qualify(self.me, &s.name);
                for field in &mut s.fields {
                    self.type_expr(&mut field.ty);
                }
                for m in &mut s.methods {
                    self.function(m);
                }
            }
            Item::Enum(e) => {
                e.name = self.qualify(self.me, &e.name);
                for variant in &mut e.variants {
                    for field in &mut variant.fields {
                        self.type_expr(field);
                    }
                }
            }
            Item::Interface(i) => {
                i.name = self.qualify(self.me, &i.name);
                for m in &mut i.methods {
                    for p in &mut m.params {
                        self.type_expr(&mut p.ty);
                    }
                    if let Some(ret) = &mut m.ret {
                        self.type_expr(ret);
                    }
                }
            }
            Item::Global(stmt) => {
                if let StmtKind::Let { name, ty, init, .. } = &mut stmt.kind {
                    if let Some(ty) = ty {
                        self.type_expr(ty);
                    }
                    self.expr(init);
                    *name = self.qualify(self.me, name);
                }
            }
            Item::Check { body, .. } => self.block(body),
            Item::Import { .. } => {}
        }
    }

    fn function(&mut self, f: &mut FnDecl) {
        let mut scope = HashSet::new();
        if f.has_self {
            scope.insert("self".to_string());
        }
        for p in &mut f.params {
            self.type_expr(&mut p.ty);
            scope.insert(p.name.clone());
        }
        if let Some(ret) = &mut f.ret {
            self.type_expr(ret);
        }
        self.scopes.push(scope);
        for stmt in &mut f.body.stmts {
            self.stmt(stmt);
        }
        self.scopes.pop();
    }

    fn block(&mut self, block: &mut Block) {
        self.scopes.push(HashSet::new());
        for stmt in &mut block.stmts {
            self.stmt(stmt);
        }
        self.scopes.pop();
    }

    fn stmt(&mut self, stmt: &mut Stmt) {
        match &mut stmt.kind {
            StmtKind::Let { name, ty, init, .. } => {
                if let Some(ty) = ty {
                    self.type_expr(ty);
                }
                self.expr(init);
                let name = name.clone();
                self.declare(&name);
            }
            StmtKind::Assign { target, value, .. } => {
                self.expr(target);
                self.expr(value);
            }
            StmtKind::Expr(e) | StmtKind::Fail(e) => self.expr(e),
            StmtKind::If { cond, then, els } => {
                self.expr(cond);
                self.block(then);
                if let Some(els) = els {
                    self.stmt(els);
                }
            }
            StmtKind::While { cond, body } => {
                self.expr(cond);
                self.block(body);
            }
            StmtKind::For { var, iter, body, .. } => {
                self.expr(iter);
                self.scopes.push(HashSet::from([var.clone()]));
                self.block(body);
                self.scopes.pop();
            }
            StmtKind::Return(value) => {
                if let Some(v) = value {
                    self.expr(v);
                }
            }
            StmtKind::Break | StmtKind::Continue => {}
            StmtKind::Fork(body) | StmtKind::Block(body) => self.block(body),
            StmtKind::Send { chan, value } => {
                self.expr(chan);
                self.expr(value);
            }
            StmtKind::Match { subject, arms, default } => {
                self.expr(subject);
                for arm in arms {
                    let mut names = HashSet::new();
                    for pattern in &mut arm.patterns {
                        match pattern {
                            Pattern::Literal(value) => self.expr(value),
                            Pattern::Variant { bindings, .. } => names.extend(bindings.iter().map(|(name, _)| name.clone())),
                        }
                    }
                    self.scopes.push(names);
                    self.block(&mut arm.body);
                    self.scopes.pop();
                }
                if let Some(body) = default {
                    self.block(body);
                }
            }
        }
    }

    fn expr(&mut self, e: &mut Expr) {
        // `module.item` becomes a plain name.
        if let ExprKind::Field { obj, name, name_span } = &e.kind {
            if let ExprKind::Ident(alias) = &obj.kind {
                if !self.is_local(alias) {
                    if let Some(&module) = self.imports.get(alias) {
                        let info = &self.infos[module];
                        if info.values.contains(name) {
                            let (name, span) = (name.clone(), *name_span);
                            self.check_private(module, &name, span);
                            e.kind = ExprKind::Ident(self.qualify(module, &name));
                        } else if info.types.contains(name) {
                            // `module.Enum`, on its way to `module.Enum.Variant`.
                            let (name, span) = (name.clone(), *name_span);
                            self.check_private(module, &name, span);
                            e.kind = ExprKind::Ident(self.qualify(module, &name));
                        } else {
                            let d = if info.types.contains(name) {
                                Diagnostic::new("E0401", format!("`{alias}.{name}` is a type, not a value"), *name_span)
                            } else {
                                Diagnostic::new("E0401", format!("module `{alias}` has no function or variable `{name}`"), *name_span)
                            };
                            self.diags.push(d);
                        }
                        return;
                    }
                }
            }
        }
        if let ExprKind::Call { callee, args } = &e.kind {
            if matches!(&callee.kind, ExprKind::Ident(name) if name == "embed" && !self.is_local(name)) {
                if let Some(text) = self.embed(args, e.span) {
                    e.kind = text;
                }
                return;
            }
        }
        match &mut e.kind {
            ExprKind::Int(_) | ExprKind::Float(_) | ExprKind::Bool(_) => {}
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        self.expr(inner);
                    }
                }
            }
            ExprKind::Ident(name) => {
                let mine = &self.infos[self.me];
                // A type name in an expression is an enum: `Shape.Circle(1.0)`.
                if !self.is_local(name) && (mine.values.contains(name.as_str()) || mine.types.contains(name.as_str())) {
                    *name = self.qualify(self.me, name);
                }
            }
            ExprKind::List(items) => {
                for item in items {
                    self.expr(item);
                }
            }
            ExprKind::Map(entries) => {
                for (k, v) in entries {
                    self.expr(k);
                    self.expr(v);
                }
            }
            ExprKind::StructLit { name, name_span, fields } => {
                self.type_name(name, *name_span);
                for f in fields {
                    self.expr(&mut f.value);
                }
            }
            ExprKind::Unary { expr, .. } | ExprKind::Try(expr) | ExprKind::Recv(expr) => self.expr(expr),
            ExprKind::Binary { lhs, rhs, .. } => {
                self.expr(lhs);
                self.expr(rhs);
            }
            ExprKind::Call { callee, args } => {
                self.expr(callee);
                for a in args {
                    self.expr(a);
                }
            }
            ExprKind::Field { obj, .. } => self.expr(obj),
            ExprKind::Index { obj, index } => {
                self.expr(obj);
                self.expr(index);
            }
            ExprKind::Lambda { params, ret, body, .. } => {
                let mut scope = HashSet::new();
                for p in params {
                    self.type_expr(&mut p.ty);
                    scope.insert(p.name.clone());
                }
                if let Some(ret) = ret {
                    self.type_expr(ret);
                }
                self.scopes.push(scope);
                for stmt in &mut body.stmts {
                    self.stmt(stmt);
                }
                self.scopes.pop();
            }
            ExprKind::Or { expr, default } => {
                self.expr(expr);
                self.expr(default);
            }
            ExprKind::Catch { expr, name, body, .. } => {
                self.expr(expr);
                self.scopes.push(HashSet::from([name.clone()]));
                for stmt in &mut body.stmts {
                    self.stmt(stmt);
                }
                self.scopes.pop();
            }
            ExprKind::ChanNew { elem, cap } => {
                self.type_expr(elem);
                if let Some(cap) = cap {
                    self.expr(cap);
                }
            }
            ExprKind::Range { lo, hi } => {
                self.expr(lo);
                self.expr(hi);
            }
        }
    }
}
