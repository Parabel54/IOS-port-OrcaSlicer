#!/usr/bin/env python3
"""Regenerate iOS settings locations from desktop Orca's Tab.cpp."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]


def function_body(source, name):
    start = re.search(r'(?:void|PageShp) ' + re.escape(name) + r'\(', source).end()
    start = source.index('{', start)
    depth = 0
    # Ignore braces in translated labels, character literals and lambdas' strings.
    for match in re.finditer(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[{}]", source[start:]):
        token = match[0]
        if token == '{':
            depth += 1
        elif token == '}':
            depth -= 1
            if depth == 0:
                return source[start:start + match.end()]
    raise ValueError(f'Unclosed desktop settings function: {name}')


def expand_option_loops(body):
    vectors = {m[1]: re.findall(r'"([^"\n]+)"', m[2]) for m in
               re.finditer(r'std::vector<std::string>\s+(\w+)\s*\{([^}]+)\}', body)}
    pattern = r'for\s*\(const std::string\s*&\s*(\w+)\s*:\s*(\w+)\)\s*\{([^{}]+)\}'
    def expand(match):
        variable, vector, statements = match.groups()
        if vector not in vectors or 'append_option_line' not in statements:
            return match[0]
        result = ''.join(re.sub(r'\b' + variable + r'\b', json.dumps(value), statements) for value in vectors[vector])
        return re.sub(r'"([^"\n]*)"\s*\+\s*"([^"\n]*)"', lambda m: json.dumps(m[1] + m[2]), result)
    return re.sub(pattern, expand, body)


def catalog():
    source = (ROOT / 'src/slic3r/GUI/Tab.cpp').read_text()
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    locations, pages = {}, {}
    functions = [(0, 'TabPrint::build'), (1, 'TabFilament::build'),
                 (2, 'TabPrinter::build_fff'), (2, 'TabPrinter::build_kinematics_page'),
                 (2, 'TabPrinter::build_unregular_pages')]
    for scope, function in functions:
        body = expand_option_loops(function_body(source, function))
        page, group = 'Other', 'General'
        pages.setdefault(scope, [])
        pattern = (r'add_options_page\(L\("([^"]+)"\)|new_optgroup\(L\("([^"]+)"\)|'
                   r'(?:append_single_option_line|get_option|append_option_line)\([^"\n]*"([a-z][a-z0-9_]+)"|'
                   r'create_line_with_widget\([^"\n]*"([a-z][a-z0-9_]+)"')
        for match in re.finditer(pattern, body):
            if match[1]:
                page = match[1]
                if page not in pages[scope]:
                    pages[scope].append(page)
            elif match[2]:
                group = match[2]
            else:
                key = match[3] or match[4]
                locations.setdefault(f'{scope}:{key}', (page, group, len(locations)))
    # Desktop inserts dynamic printer pages into m_pages, rather than appending
    # them in function-definition order (build_unregular_pages).
    pages[2] = ['Basic information', 'Machine G-code', 'Multimaterial', 'Extruder', 'Motion ability', 'Notes']
    return locations, pages


def generated():
    locations, pages = catalog()
    return '''// Generated from desktop Tab.cpp; regenerate with scripts/generate_ios_settings.py.
enum DesktopSettings {
    struct Location { let page: String; let group: String; let order: Int }
    static func location(_ entry: ConfigOptionEntry) -> Location {
        locations["\\(entry.scope):\\(entry.key)"] ?? Location(page: entry.displayCategory, group: "Additional settings", order: 10000)
    }
    static func pageOrder(_ page: String, scope: Int) -> Int {
        pages[scope]?.firstIndex(of: page) ?? 10000
    }
    static let pages: [Int: [String]] = [
''' + ''.join(f'        {k}: {json.dumps(v)},\n' for k, v in pages.items()) + '''    ]
    static let locations: [String: Location] = [
''' + ''.join('        ' + json.dumps(k) + ': Location(page: ' + json.dumps(v[0]) + ', group: ' + json.dumps(v[1]) + ', order: ' + str(v[2]) + '),\n' for k, v in locations.items()) + '    ]\n}\n'


if __name__ == '__main__':
    path = ROOT / 'ios/OrcaSlicerApp/ProcessOptions.swift'
    source = path.read_text()
    start = source.index('// Generated from desktop Tab.cpp;')
    end = source.index('\n/// Native hook configuration', start)
    path.write_text(source[:start] + generated() + source[end:])
