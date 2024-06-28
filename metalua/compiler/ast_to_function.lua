-------------------------------------------------------------------------------
-- Copyright (c) 2006-2013 Fabien Fleutot and others.
--
-- All rights reserved.
--
-- This program and the accompanying materials are made available
-- under the terms of the Eclipse Public License v1.0 which
-- accompanies this distribution, and is available at
-- http://www.eclipse.org/legal/epl-v10.html
--
-- This program and the accompanying materials are also made available
-- under the terms of the MIT public license which accompanies this
-- distribution, and is available at http://www.lua.org/license.html
--
-- Contributors:
--     Fabien Fleutot - API and implementation
--
-------------------------------------------------------------------------------


local M = { }
M.__index = M

local pp=require 'metalua.pprint'

--------------------------------------------------------------------------------
-- Instanciate a new AST->source synthetizer
--------------------------------------------------------------------------------
function M.new ()
    local self = {
        _acc           = { },  -- Accumulates pieces of source as strings
        current_indent = 0,    -- Current level of line indentation
        indent_step    = "   " -- Indentation symbol, normally spaces or '\t'
    }
    return setmetatable (self, M)
end

--------------------------------------------------------------------------------
-- Run a synthetizer on the `ast' arg and return the source as a string.
-- Can also be used as a static method `M.run (ast)'; in this case,
-- a temporary Metizer is instanciated on the fly.
--------------------------------------------------------------------------------
function M:run (ast)
    if not ast then
        self, ast = M.new(), self
    end
    self._acc = { }
    self:node (ast)
    return table.concat (self._acc)
end

--------------------------------------------------------------------------------
-- Accumulate a piece of source file in the synthetizer.
--------------------------------------------------------------------------------
function M:acc (x)
    if x then table.insert (self._acc, x) end
end

--------------------------------------------------------------------------------
-- Accumulate an indented newline.
-- Jumps an extra line if indentation is 0, so that
-- toplevel definitions are separated by an extra empty line.
--------------------------------------------------------------------------------
function M:nl ()
    if self.current_indent == 0 then self:acc "\n"  end
    self:acc ("\n" .. self.indent_step:rep (self.current_indent))
end

--------------------------------------------------------------------------------
-- Increase indentation and accumulate a new line.
--------------------------------------------------------------------------------
function M:nlindent ()
    self.current_indent = self.current_indent + 1
    self:nl ()
end

--------------------------------------------------------------------------------
-- Decrease indentation and accumulate a new line.
--------------------------------------------------------------------------------
function M:nldedent ()
    self.current_indent = self.current_indent - 1
    self:acc ("\n" .. self.indent_step:rep (self.current_indent))
end

--------------------------------------------------------------------------------
-- Keywords, which are illegal as identifiers.
--------------------------------------------------------------------------------
local keywords_list = {
    "and",    "break",   "do",    "else",   "elseif",
    "end",    "false",   "for",   "function", "if",
    "in",     "local",   "nil",   "not",    "or",
    "repeat", "return",  "then",  "true",   "until",
    "while" }
local keywords = { }
for _, kw in pairs(keywords_list) do keywords[kw]=true end

--------------------------------------------------------------------------------
-- Return true iff string `id' is a legal identifier name.
--------------------------------------------------------------------------------
local function is_ident (id)
    return string['match'](id, "^[%a_][%w_]*$") and not keywords[id]
end

--------------------------------------------------------------------------------
-- 另一个版本的match, 为了自动兼容各版本的lua, 序列改为 src->ast->src ,这个过程调用 ast_to_src.mlua 会无限递归.所以要实现一个纯lua版本的
--------------------------------------------------------------------------------
local function is_match_and_capture(match_cfg, ast, cap)
    if(match_cfg == true)then
        return true
    end
    if(match_cfg.tag ~= nil and ast.tag ~=  match_cfg.tag)then
        return false
    end
    if(match_cfg.cap ~= nil)then
        cap[match_cfg.cap] = ast
    end
    for idx, v in ipairs(match_cfg)do
        local tp = type(v)
        if(tp == "string")then
            cap[v] = ast[idx]
            -- capture
        elseif(tp == "table")then
            if(v.cap ~= nil)then
                cap[v.cap] = ast[idx]
            end
            local isMatch =  is_match_and_capture(v,ast[idx], cap)
            if(not isMatch)then
                return false
            end
        else
            assert(false, "notSupportTp:"..tp)
        end
    end
    return true
end

local function  eval_match(cfgs, ast, mode)
    for _, cfg in ipairs(cfgs)do
        local cap = {}
        if(is_match_and_capture(cfg[1], ast, cap))then
            if(cfg[2] == nil or(cfg[2](cap)) )then
                cfg[3](mode,cap)
                return
            end
            break
        end
    end
    assert(false,"not all branch matched")
end

--------------------------------------------------------------------------------
-- Return true iff ast represents a legal function name for
-- syntax sugar ``function foo.bar.gnat() ... end'':
-- a series of nested string indexes, with an identifier as
-- the innermost node.
--------------------------------------------------------------------------------
local function is_idx_stack (ast)
    if(ast.tag == 'Id')then
        return true
    end
    if(ast.tag == "Index" and ast[2] ~= nil and ast[2].tag == "String")then
        return is_idx_stack(ast[1])
    end
    return false
    --match ast with
    --| `Id{ _ }                     -> return true
    --| `Index{ left, `String{ _ } } -> return is_idx_stack (left)
    --| _                            -> return false
    --end
end

--------------------------------------------------------------------------------
-- Operator precedences, in increasing order.
-- This is not directly used, it's used to generate op_prec below.
--------------------------------------------------------------------------------
local op_preprec = {
    { "or", "and" },
    { "lt", "le", "eq", "ne" },
    { "concat" },
    { "add", "sub" },
    { "mul", "div", "mod" },
    { "unary", "not", "len" },
    { "pow" },
    { "index" } }

--------------------------------------------------------------------------------
-- operator --> precedence table, generated from op_preprec.
--------------------------------------------------------------------------------
local op_prec = { }

for prec, ops in ipairs (op_preprec) do
    for _, op in ipairs (ops) do
        op_prec[op] = prec
    end
end

--------------------------------------------------------------------------------
-- operator --> source representation.
--------------------------------------------------------------------------------
local op_symbol = {
    add    = " + ",   sub     = " - ",   mul     = " * ",
    div    = " / ",   mod     = " % ",   pow     = " ^ ",
    concat = " .. ",  eq      = " == ",  ne      = " ~= ",
    lt     = " < ",   le      = " <= ",  ["and"] = " and ",
    ["or"] = " or ",  ["not"] = "not ",  len     = "# " }

--------------------------------------------------------------------------------
-- Accumulate the source representation of AST `node' in
-- the synthetizer. Most of the work is done by delegating to
-- the method having the name of the AST tag.
-- If something can't be converted to normal sources, it's
-- instead dumped as a `-{ ... }' splice in the source accumulator.
--------------------------------------------------------------------------------
function M:node (node)
    assert (self~=M and self._acc)
    if node==nil then self:acc'<<error>>'; return end
    if not node.tag then -- tagless block.
        self:list (node, self.nl)
    else
        local f = M[node.tag]
        if type (f) == "function" then -- Delegate to tag method.
            f (self, node, table.unpack (node))
        elseif type (f) == "string" then -- tag string.
            self:acc (f)
        else -- No appropriate method, fall back to splice dumping.
            -- This cannot happen in a plain Lua AST.
            self:acc " -{ "
            self:acc (pp.tostring (node, {metalua_tag=1, hide_hash=1}), 80)
            self:acc " }"
        end
    end
end

--------------------------------------------------------------------------------
-- Convert every node in the AST list `list' passed as 1st arg.
-- `sep' is an optional separator to be accumulated between each list element,
-- it can be a string or a synth method.
-- `start' is an optional number (default == 1), indicating which is the
-- first element of list to be converted, so that we can skip the begining
-- of a list.
--------------------------------------------------------------------------------
function M:list (list, sep, start)
    for i = start or 1, # list do
        self:node (list[i])
        if list[i + 1] then
            if not sep then
            elseif type (sep) == "function" then sep (self)
            elseif type (sep) == "string"   then self:acc (sep)
            else   error "Invalid list separator" end
        end
    end
end

--------------------------------------------------------------------------------
--
-- Tag methods.
-- ------------
--
-- Specific AST node dumping methods, associated to their node kinds
-- by their name, which is the corresponding AST tag.
-- synth:node() is in charge of delegating a node's treatment to the
-- appropriate tag method.
--
-- Such tag methods are called with the AST node as 1st arg.
-- As a convenience, the n node's children are passed as args #2 ... n+1.
--
-- There are several things that could be refactored into common subroutines
-- here: statement blocks dumping, function dumping...
-- However, given their small size and linear execution
-- (they basically perform series of :acc(), :node(), :list(),
-- :nl(), :nlindent() and :nldedent() calls), it seems more readable
-- to avoid multiplication of such tiny functions.
--
-- To make sense out of these, you need to know metalua's AST syntax, as
-- found in the reference manual or in metalua/doc/ast.txt.
--
--------------------------------------------------------------------------------

function M:Do (node)
    self:acc      "do"
    self:nlindent ()
    self:list     (node, self.nl)
    self:nldedent ()
    self:acc      "end"
end

function M:Set (node)
    pp.printf("===? s", node)
    eval_match({
        {
            {
                tag="Set",
                {tag="Index","lhs",{tag="String", "method"}},
                {tag="Function",{cap = "params",tag="Id", "first"}, "body"}
            },{
                function(cap)
                    return cap.first == "self" and is_idx_stack(cap.lhs) and is_ident(cap.method)
                end
            },function(_self, cap)
                _self:acc      "function "
                _self:node     (cap.lhs)
                _self:acc      ":"
                _self:acc      (cap.method)
                _self:acc      " ("
                _self:list     (cap.params, ", ", 2)
                _self:acc      ")"
                _self:nlindent ()
                _self:list     (cap.body, self.nl)
                _self:nldedent ()
                _self:acc      "end"
            end
        },
        {
            {
                tag="Set",
                "lhs",
                {tag="Function","params", "body"}
            },{
                function(cap)
                    return is_idx_stack(cap.lhs)
                end
            },function(_self, cap)
                _self:acc      "function "
                _self:node     (cap.lhs)
                _self:acc      " ("
                _self:list     (cap.params, ", ")
                _self:acc      ")"
                _self:nlindent ()
                _self:list     (cap.body, _self.nl)
                _self:nldedent ()
                _self:acc      "end"
            end
        },
        {
            {
                tag="Set",
                {cap = "lhs", {cap="lhs1",{tag="Id", "lhs1name"}}},
                "rhs"
            },
            {
                function(cap)
                    return is_ident(cap.lhs1name)
                    --return (cap.lhs.tag == "Id" and not is_ident(cap.lhs[1]))
                    --return is_idx_stack(cap.lhs) and is_ident(cap.method)
                end
            },
            function(_self, cap)
                _self:acc      "("
                _self:node     (cap.lhs1)
                _self:acc      ")"
                if cap.lhs[2] then -- more than one lhs variable
                    _self:acc   ", "
                    _self:list  (cap.lhs, ", ", 2)
                end
                _self:acc      " = "
                _self:list     (cap.rhs, ", ")
            end
        },
        {
            {
                tag="Set",
                "lhs",
                "rhs"
            },nil,function(_self, cap)
                _self:list     (cap.lhs, ", ")
                _self:acc      " = "
                _self:list     (cap.rhs, ", ")
            end
        },
        {
            {
                tag="Set",
                "lhs",
                "rhs",
                "annot"
            },nil,function(_self, cap)
                local n = #cap.lhs
                for i=1,n do
                    local ell, a = cap.lhs[i], cap.annot[i]
                    _self:node (ell)
                    if a then
                        _self:acc ' #'
                        _self:node(a)
                    end
                    if i~=n then _self:acc ', ' end
                end
                _self:acc   " = "
                _self:list  (cap.rhs, ", ")
            end
        }
    }, node, self)
    --{tag="Function","params", "body"}
    --match node with
    --| `Set{ { `Index{ lhs, `String{ method } } },
    --        { `Function{ { `Id "self", ... } == params, body } } }
    --      if is_idx_stack (lhs) and is_ident (method) ->
    --   -- ``function foo:bar(...) ... end'' --
    --   self:acc      "function "
    --   self:node     (lhs)
    --   self:acc      ":"
    --   self:acc      (method)
    --   self:acc      " ("
    --   self:list     (params, ", ", 2)
    --   self:acc      ")"
    --   self:nlindent ()
    --   self:list     (body, self.nl)
    --   self:nldedent ()
    --   self:acc      "end"

    --| `Set{ { lhs }, { `Function{ params, body } } } if is_idx_stack (lhs) ->
    --   -- ``function foo(...) ... end'' --
    --   self:acc      "function "
    --   self:node     (lhs)
    --   self:acc      " ("
    --   self:list     (params, ", ")
    --   self:acc      ")"
    --   self:nlindent ()
    --   self:list    (body, self.nl)
    --   self:nldedent ()
    --   self:acc      "end"

    --| `Set{ { `Id{ lhs1name } == lhs1, ... } == lhs, rhs }
    --      if not is_ident (lhs1name) ->
    --   -- ``foo, ... = ...'' when foo is *not* a valid identifier.
    --   -- In that case, the spliced 1st variable must get parentheses,
    --   -- to be distinguished from a statement splice.
    --   -- This cannot happen in a plain Lua AST.
    --   self:acc      "("
    --   self:node     (lhs1)
    --   self:acc      ")"
    --   if lhs[2] then -- more than one lhs variable
    --      self:acc   ", "
    --      self:list  (lhs, ", ", 2)
    --   end
    --   self:acc      " = "
    --   self:list     (rhs, ", ")

    --| `Set{ lhs, rhs } ->
    --   -- ``... = ...'', no syntax sugar --
    --   self:list  (lhs, ", ")
    --   self:acc   " = "
    --   self:list  (rhs, ", ")
    --| `Set{ lhs, rhs, annot } ->
    --   -- ``... = ...'', no syntax sugar, annotation --
    --   local n = #lhs
    --   for i=1,n do
    --       local ell, a = lhs[i], annot[i]
    --       self:node (ell)
    --       if a then
    --           self:acc ' #'
    --           self:node(a)
    --       end
    --       if i~=n then self:acc ', ' end
    --   end
    --   self:acc   " = "
    --   self:list  (rhs, ", ")
    --end
end

function M:While (node, cond, body)
    self:acc      "while "
    self:node     (cond)
    self:acc      " do"
    self:nlindent ()
    self:list     (body, self.nl)
    self:nldedent ()
    self:acc      "end"
end

function M:Repeat (node, body, cond)
    self:acc      "repeat"
    self:nlindent ()
    self:list     (body, self.nl)
    self:nldedent ()
    self:acc      "until "
    self:node     (cond)
end

function M:If (node)
    for i = 1, #node-1, 2 do
        -- for each ``if/then'' and ``elseif/then'' pair --
        local cond, body = node[i], node[i+1]
        self:acc      (i==1 and "if " or "elseif ")
        self:node     (cond)
        self:acc      " then"
        self:nlindent ()
        self:list     (body, self.nl)
        self:nldedent ()
    end
    -- odd number of children --> last one is an `else' clause --
    if #node%2 == 1 then
        self:acc      "else"
        self:nlindent ()
        self:list     (node[#node], self.nl)
        self:nldedent ()
    end
    self:acc "end"
end

function M:Fornum (node, var, first, last)
    local body = node[#node]
    self:acc      "for "
    self:node     (var)
    self:acc      " = "
    self:node     (first)
    self:acc      ", "
    self:node     (last)
    if #node==5 then -- 5 children --> child #4 is a step increment.
        self:acc   ", "
        self:node  (node[4])
    end
    self:acc      " do"
    self:nlindent ()
    self:list     (body, self.nl)
    self:nldedent ()
    self:acc      "end"
end

function M:Forin (node, vars, generators, body)
    self:acc      "for "
    self:list     (vars, ", ")
    self:acc      " in "
    self:list     (generators, ", ")
    self:acc      " do"
    self:nlindent ()
    self:list     (body, self.nl)
    self:nldedent ()
    self:acc      "end"
end

function M:Local (node, lhs, rhs, annots)
    if next (lhs) then
        self:acc     "local "
        if annots then
            local n = #lhs
            for i=1, n do
                self:node (lhs)
                local a = annots[i]
                if a then
                    self:acc ' #'
                    self:node (a)
                end
                if i~=n then self:acc ', ' end
            end
        else
            self:list    (lhs, ", ")
        end
        if rhs[1] then
            self:acc  " = "
            self:list (rhs, ", ")
        end
    else -- Can't create a local statement with 0 variables in plain Lua
        self:acc (table.tostring (node, 'nohash', 80))
    end
end

function M:Localrec (node, lhs, rhs)
    eval_match({
        {
            {
                tag="Localrec",
                {tag="Id","name"},
                {tag="Function","params","body"},
            },
            function(cap)
                return is_ident(cap.name)
            end,
            function(_self, cap)
                _self:acc      "local function "
                _self:acc      (cap.name)
                _self:acc      " ("
                _self:list     (cap.params, ", ")
                _self:acc      ")"
                _self:nlindent ()
                _self:list     (cap.body, _self.nl)
                _self:nldedent ()
                _self:acc      "end"
            end

        },{
            true,nil,
            function(_self, cap)
                _self:acc "-{ "
                _self:acc (table.tostring (node, 'nohash', 80))
                _self:acc " }"
            end
        }
    }, node,self)
    --match node with
    --| `Localrec{ { `Id{name} }, { `Function{ params, body } } }
    --      if is_ident (name) ->
    --   -- ``local function name() ... end'' --
    --   self:acc      "local function "
    --   self:acc      (name)
    --   self:acc      " ("
    --   self:list     (params, ", ")
    --   self:acc      ")"
    --   self:nlindent ()
    --   self:list     (body, self.nl)
    --   self:nldedent ()
    --   self:acc      "end"

    --| _ ->
    --   -- Other localrec are unprintable ==> splice them --
    --       -- This cannot happen in a plain Lua AST. --
    --   self:acc "-{ "
    --   self:acc (table.tostring (node, 'nohash', 80))
    --   self:acc " }"
    --end
end

function M:Call (node, f)
    -- single string or table literal arg ==> no need for parentheses. --
    -- but I don't like it. all need parentheses

    local parens = true
    if(node.tag == "Call")then
        if(
            (node[2]~= nil and node[2].tag == "String")
            or
            (node[2]~= nil and node[2].tag == "Table")
        )then
                parens = false
        end
    end
    --match node with
    --| `Call{ _, `String{_} }
    --| `Call{ _, `Table{...}} -> parens = false
    --| _ -> parens = true
    --end
    self:node (f)
    self:acc  (parens and " (" or  " ")
    self:list (node, ", ", 2) -- skip `f'.
    self:acc  (parens and ")")
end

function M:Invoke (node, f, method)
    -- single string or table literal arg ==> no need for parentheses. --
    local parens = true
    if(node.tag == "Invoke")then
        if(
            (node[3]~= nil and node[3].tag == "String")
            or
            (node[3]~= nil and node[3].tag == "Table")
        )then
                parens = false
        end
    end

    --match node with
    --| `Invoke{ _, _, `String{_} }
    --| `Invoke{ _, _, `Table{...}} -> parens = false
    --| _ -> parens = true
    --end
    self:node   (f)
    self:acc    ":"
    self:acc    (method[1])
    self:acc    (parens and " (" or  " ")
    self:list   (node, ", ", 3) -- Skip args #1 and #2, object and method name.
    self:acc    (parens and ")")
end

function M:Return (node)
    self:acc  "return "
    self:list (node, ", ")
end

M.Break = "break"
M.Nil   = "nil"
M.False = "false"
M.True  = "true"
M.Dots  = "..."

function M:Number (node, n)
    self:acc (tostring (n))
end

function M:String (node, str)
    -- format "%q" prints '\n' in an umpractical way IMO,
    -- so this is fixed with the :gsub( ) call.
    self:acc (string.format ("%q", str):gsub ("\\\n", "\\n"))
end

function M:Function (node, params, body, annots)
    self:acc      "function ("
    if annots then
        local n = #params
        for i=1,n do
            local p, a = params[i], annots[i]
            self:node(p)
            if annots then
                self:acc " #"
                self:node(a)
            end
            if i~=n then self:acc ', ' end
        end
    else
        self:list (params, ", ")
    end
    self:acc      ")"
    self:nlindent ()
    self:list     (body, self.nl)
    self:nldedent ()
    self:acc      "end"
end

function M:Table (node)
    if not node[1] then
        self:acc "{ }"
    else
        self:acc "{"
        if #node > 1 then self:nlindent () else self:acc " " end
        for i, elem in ipairs (node) do
            eval_match({
                {
                    {tag="Pair",{tag="String", "key"}, "value"},
                    function(cap)
                        return is_ident(cap.key)
                    end,
                    function(_self, cap)
                        _self:acc  (cap.key)
                        _self:acc  " = "
                        _self:node (cap.value)
                    end
                },
                {
                    {tag="Pair","key", "value"},
                    nil,
                    function(_self, cap)
                        _self:acc  ("[")
                        _self:acc  (cap.key)
                        _self:acc  "] = "
                        _self:node (cap.value)
                    end
                },
                {
                    true,nil,
                    function (_self, cap)
                        
                        _self:node (elem)
                    end
                }
            }, elem, self)
            --match elem with
            --| `Pair{ `String{ key }, value } if is_ident (key) ->
            --   -- ``key = value''. --
            --   self:acc  (key)
            --   self:acc  " = "
            --   self:node (value)

            --| `Pair{ key, value } ->
            --   -- ``[key] = value''. --
            --   self:acc  "["
            --   self:node (key)
            --   self:acc  "] = "
            --   self:node (value)

            --| _ ->
            --   -- ``value''. --
            --   self:node (elem)
            --end
            if node [i+1] then
                self:acc ","
                self:nl  ()
            end
        end
        if #node > 1 then self:nldedent () else self:acc " " end
        self:acc       "}"
    end
end

function M:Op (node, op, a, b)
    -- Transform ``not (a == b)'' into ``a ~= b''. --
    if(node.tag == "Op" and node[1] == "not")then
        if(node[2].tag == "Op" and node[2][1].tag == "eq")then
            a, b =  node[2][2],node[2][3]
        elseif(node[2].tag == "Paren" and node[2][1].tag == "Op" and 
            node[2][1][1].tag == "eq"
        )then
            a, b =  node[2][1][2],node[2][1][3]
        end
        op = "ne"
    end
    --match node with
    --| `Op{ "not", `Op{ "eq", _a, _b } }
    --| `Op{ "not", `Paren{ `Op{ "eq", _a, _b } } } ->
    --   op, a, b = "ne", _a, _b
    --| _ ->
    --end

    if b then -- binary operator.
        local left_paren, right_paren = false, false
        if(a.tag == "Op")then
            if(op_prec[op] >=op_prec[a[1]])then
                left_paren = true
            end
        end
        --match a with
        --| `Op{ op_a, ...} if op_prec[op] >= op_prec[op_a] -> left_paren = true
        --| _ -> left_paren = false
        --end
        if(b.tag == "Op")then
            if(op_prec[op] >=op_prec[b[1]])then
                right_paren = true
            end
        end

        --match b with -- FIXME: might not work with right assoc operators ^ and ..
        --| `Op{ op_b, ...} if op_prec[op] >= op_prec[op_b] -> right_paren = true
        --| _ -> right_paren = false
        --end

        self:acc  (left_paren and "(")
        self:node (a)
        self:acc  (left_paren and ")")

        self:acc  (op_symbol [op])

        self:acc  (right_paren and "(")
        self:node (b)
        self:acc  (right_paren and ")")

    else -- unary operator.
        local paren
        if(a.tag == "Op")then
            if(op_prec[op] >=op_prec[a[1]])then
                paren = true
            end
        end

        --match a with
        --| `Op{ op_a, ... } if op_prec[op] >= op_prec[op_a] -> paren = true
        --| _ -> paren = false
        --end
        self:acc  (op_symbol[op])
        self:acc  (paren and "(")
        self:node (a)
        self:acc  (paren and ")")
    end
end

function M:Paren (node, content)
    self:acc  "("
    self:node (content)
    self:acc  ")"
end

function M:Index (node, table, key)
    local paren_table = false
    if(table.tag == "Op")then
        local op = table[1]
        if(op_prec[op] < op_prec.index)then
            paren_table = true
        end
    end
    -- Check precedence, see if parens are needed around the table --
    --match table with
    --| `Op{ op, ... } if op_prec[op] < op_prec.index -> paren_table = true
    --| _ -> paren_table = false
    --end

    self:acc  (paren_table and "(")
    self:node (table)
    self:acc  (paren_table and ")")

    eval_match({
        {
            {tag="String","field"},
            function(cap)
                return is_ident(cap.field)
            end,
            function(_self, cap)
                _self:acc  "."
                _self:node (cap.field)
            end
        },
        {
            true,nil,
            function (_self, cap)
                _self:acc   "["
                _self:node (key)
                _self:acc   "]"
            end
        }
    }, key, self)

    --match key with
    --| `String{ field } if is_ident (field) ->
    --   -- ``table.key''. --
    --   self:acc "."
    --   self:acc (field)
    --| _ ->
    --   -- ``table [key]''. --
    --   self:acc   "["
    --   self:node (key)
    --   self:acc   "]"
    --end
end

function M:Id (node, name)
    if is_ident (name) then
        self:acc (name)
    else -- Unprintable identifier, fall back to splice representation.
        -- This cannot happen in a plain Lua AST.
        self:acc    "-{`Id "
        self:String (node, name)
        self:acc    "}"
    end
end


M.TDyn    = '*'
M.TDynbar = '**'
M.TPass   = 'pass'
M.TField  = 'field'
M.TIdbar  = M.TId
M.TReturn = M.Return


function M:TId (node, name) self:acc(name) end


function M:TCatbar(node, te, tebar)
    self:acc'('
    self:node(te)
    self:acc'|'
    self:tebar(tebar)
    self:acc')'
end

function M:TFunction(node, p, r)
    self:tebar(p)
    self:acc '->'
    self:tebar(r)
end

function M:TTable (node, default, pairs)
    self:acc '['
    self:list (pairs, ', ')
    if default.tag~='TField' then
        self:acc '|'
        self:node (default)
    end
    self:acc ']'
end

function M:TPair (node, k, v)
    self:node (k)
    self:acc '='
    self:node (v)
end

function M:TIdbar (node, name)
    self :acc (name)
end

function M:TCatbar (node, a, b)
    self:node(a)
    self:acc ' ++ '
    self:node(b)
end

function M:tebar(node)
    if node.tag then self:node(node) else
        self:acc '('
        self:list(node, ', ')
        self:acc ')'
    end
end

function M:TUnkbar(node, name)
    self:acc '~~'
    self:acc (name)
end

function M:TUnk(node, name)
    self:acc '~'
    self:acc (name)
end

for name, tag in pairs{ const='TConst', var='TVar', currently='TCurrently', just='TJust' } do
    M[tag] = function(self, node, te)
        self:acc (name..' ')
        self:node(te)
    end
end

return (function(x) return M.run(x) end)
