---------------------------------------------------------------------------
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
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
--
-- Convert between various code representation formats. Atomic
-- converters are written in extenso, others are composed automatically
-- by chaining the atomic ones together in a closure.
--
-- Supported formats are:
--
-- * srcfile:    the name of a file containing sources.
-- * src:        these sources as a single string.
-- * lexstream:  a stream of lexemes.
-- * ast:        an abstract syntax tree.
-- * proto:      a (Yueliang) struture containing a high level
--               representation of bytecode. Largely based on the
--               Proto structure in Lua's VM
-- * bytecode:   a string dump of the function, as taken by
--               loadstring() and produced by string.dump().
-- * function:   an executable lua function in RAM.
--
--------------------------------------------------------------------------------

require 'checks'

local M  = { }

--------------------------------------------------------------------------------
-- Order of the transformations. if 'a' is on the left of 'b', then a 'a' can
-- be transformed into a 'b' (but not the other way around).
-- M.sequence goes for numbers to format names, M.order goes from format
-- names to numbers.
--------------------------------------------------------------------------------
--M.sequence = {
--	'srcfile',  'src', 'lexstream', 'ast', 'proto', 'bytecode', 'function' 
--}

-- FF by faruba
--------------------------------------------------------------------------------
-- 我觉得bytecode 阶段没有什么必要,从使用者的角度上来说,到AST这层就够了,如果走 src => lexer => ast
-- => generator => src 那就只要保证最终生成的代码是符合语法的,那么就可以自动适配各种版本的lua.
-- 如何lua的版本变化导致语法扩充, 简单的扩展/修改 generator 就可以了, 不需要考虑如何处理bytecode
-- 我要做的是CTMP(complie time meta programing),而且尽量不依赖于lua宿主环境.不触及btyecode还是
-- 可以的,
--------------------------------------------------------------------------------
M.sequence = {
	'srcfile',  'src', 'lexstream', 'ast', 'function'
}
local arg_types = {
	srcfile    = { 'string', '?string' },
	src        = { 'string', '?string' },
	lexstream  = { 'lexer.stream', '?string' },
	ast        = { 'table', '?string' },
	proto      = { 'table', '?string' },
	bytecode   = { 'string', '?string' },
}

if false then
    -- if defined, runs on every newly-generated AST
    function M.check_ast(ast)
        local function rec(x, n, parent)
            if not x.lineinfo and parent.lineinfo then
                local pp = require 'metalua.pprint'
                pp.printf("WARNING: Missing lineinfo in child #%s `%s{...} of node at %s",
                          n, x.tag or '', tostring(parent.lineinfo))
            end
            for i, child in ipairs(x) do
                if type(child)=='table' then rec(child, i, x) end
            end
        end
        rec(ast, -1, { })
    end
end


M.order= { }; for a,b in pairs(M.sequence) do M.order[b]=a end

local CONV = { } -- conversion metatable __index

function CONV :srcfile_to_src(x, name)
	checks('metalua.compiler', 'string', '?string')
	name = name or '@'..x
	local f, msg = io.open (x, 'rb')
	if not f then error(msg) end
	local r, msg = f :read '*a'
	if not r then error("Cannot read file '"..x.."': "..msg) end
	f :close()
	return r, name
end

function CONV :src_to_lexstream(src, name)
	checks('metalua.compiler', 'string', '?string')
	local r = self.parser.lexer :newstream (src, name)
	return r, name
end

function CONV :lexstream_to_ast(lx, name)
	checks('metalua.compiler', 'lexer.stream', '?string')
	local pp = require 'metalua.pprint'
	--pp.printf("========? %s, %s", name, lx)
	local r = self.parser.chunk(lx)
	r.source = name
    if M.check_ast then M.check_ast (r) end
	return r, name
end

local bytecode_compiler = nil -- cache to avoid repeated `pcall(require(...))`
local function get_bytecode_compiler()
    if bytecode_compiler then return bytecode_compiler else
        local status, result = pcall(require, 'metalua.compiler.bytecode')
        if status then
            bytecode_compiler = result
            return result
        elseif string.match(result, "not found") then
            error "Compilation only available with full Metalua"
        else error (result) end
    end
end

function CONV :ast_to_proto(ast, name)
	checks('metalua.compiler', 'table', '?string')
    return get_bytecode_compiler().ast_to_proto(ast, name), name
end

function CONV :proto_to_bytecode(proto, name)
    return get_bytecode_compiler().proto_to_bytecode(proto), name
end

function CONV :bytecode_to_function(bc, name)
	checks('metalua.compiler', 'string', '?string')
	return loadstring(bc, name)
end
function CONV :ast_to_function(ast, name)
	local pp = require 'metalua.pprint'
	pp.printf(">>> %s  %s",ast,name)
	--package.path = package.path .. ";3rd/lua-parser/?.lua"
	--local lpp = require 'lua-parser.pp'
	--local v = lpp.dump(ast,4)
	local ret = require 'metalua.compiler.ast_to_function' (ast)
	pp.printf("========v %s", ret)
	return ret
end

-- Create all sensible combinations
for i=1,#M.sequence do
	local src = M.sequence[i]
	for j=i+2, #M.sequence do
		local dst = M.sequence[j]
		local dst_name = src.."_to_"..dst
		local my_arg_types = arg_types[src]
		local functions = { }
		for k=i, j-1 do
			local name =  M.sequence[k].."_to_"..M.sequence[k+1]
			local f = assert(CONV[name], name)
			table.insert (functions, f)
		end
		CONV[dst_name] = function(self, a, b)
			checks('metalua.compiler', table.unpack(my_arg_types))
			for _, f in ipairs(functions) do
				a, b = f(self, a, b)
			end
			return a, b
		end
		--printf("Created M.%s out of %s", dst_name, table.concat(n, ', '))
	end
end


--------------------------------------------------------------------------------
-- This one goes in the "wrong" direction, cannot be composed.
--------------------------------------------------------------------------------
function CONV :function_to_bytecode(...) return string.dump(...) end

function CONV :ast_to_src(...)
	require 'metalua.loader' -- ast_to_string isn't written in plain lua
	return require 'metalua.compiler.ast_to_src' (...)
end

local MT = { __index=CONV, __type='metalua.compiler' }

function M.new()
	local parser = require 'metalua.compiler.parser' .new()
	local self = { parser = parser }
	setmetatable(self, MT)
	return self
end

return M
