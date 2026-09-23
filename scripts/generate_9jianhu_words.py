#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate 9jianhu progressive word index.
Supports both 9-letter codes (q, a, d, g, j, m, p, t, x) used by Trime/mobile
and numeric codes (1-9).
Includes:
1. High-frequency 2-character words from tigress_ci (4-key flow, 5-key refine, 6-key collision-free)
2. High-frequency 3-character words from tigress_ci (4-key flow, 5-key refine, 6-key collision-free, plus 3-key flow for Top words)
3. All 4-character idioms (成语) & top common 4-character words
"""

import os
import re
from collections import defaultdict

# 9 letters representing the 9 keys:
# 1:[qw]->q, 2:[abc]->a, 3:[def]->d, 4:[ghi]->g, 5:[jkl]->j, 6:[mno]->m, 7:[prs]->p, 8:[tuv]->t, 9:[xyz]->x
KEY_TO_LETTER = {
    'q': 'q', 'w': 'q',
    'a': 'a', 'b': 'a', 'c': 'a',
    'd': 'd', 'e': 'd', 'f': 'd',
    'g': 'g', 'h': 'g', 'i': 'g',
    'j': 'j', 'k': 'j', 'l': 'j',
    'm': 'm', 'n': 'm', 'o': 'm',
    'p': 'p', 'r': 'p', 's': 'p',
    't': 't', 'u': 't', 'v': 't',
    'x': 'x', 'y': 'x', 'z': 'x'
}

KEY_TO_DIGIT = {
    'q': '1', 'w': '1',
    'a': '2', 'b': '2', 'c': '2',
    'd': '3', 'e': '3', 'f': '3',
    'g': '4', 'h': '4', 'i': '4',
    'j': '5', 'k': '5', 'l': '5',
    'm': '6', 'n': '6', 'o': '6',
    'p': '7', 'r': '7', 's': '7',
    't': '8', 'u': '8', 'v': '8',
    'x': '9', 'y': '9', 'z': '9'
}

# Position selection keys:
# Pos 1: letter 'q' (key 1) or '1'
# Pos 2: letter 'a' (key 2) or '2'
# Pos 3: letter 'd' (key 3) or '3'
POS_TO_LETTER = {
    'q': 'q', 'a': 'q', 'd': 'q', 'g': 'q', 'j': 'q', 'm': 'q', 'p': 'q', 't': 'q', 'x': 'q',
    'w': 'a', 'b': 'a', 'e': 'a', 'h': 'a', 'k': 'a', 'n': 'a', 'r': 'a', 'u': 'a', 'y': 'a',
    'c': 'd', 'f': 'd', 'i': 'd', 'l': 'd', 'o': 'd', 's': 'd', 'v': 'd', 'z': 'd'
}

POS_TO_DIGIT = {
    'q': '1', 'a': '1', 'd': '1', 'g': '1', 'j': '1', 'm': '1', 'p': '1', 't': '1', 'x': '1',
    'w': '2', 'b': '2', 'e': '2', 'h': '2', 'k': '2', 'n': '2', 'r': '2', 'u': '2', 'y': '2',
    'c': '3', 'f': '3', 'i': '3', 'l': '3', 'o': '3', 's': '3', 'v': '3', 'z': '3'
}

# 2+1 collision-free matrices for 6-key input:
CHAR_GROUPS = {
    'q': 1, 'a': 1, 'd': 1, 'g': 1, 'j': 1, 'm': 1, 'p': 1, 't': 1, 'x': 1,
    'w': 2, 'b': 2, 'e': 2, 'h': 2, 'k': 2, 'n': 2, 'r': 2, 'u': 2, 'y': 2,
    'c': 3, 'f': 3, 'i': 3, 'l': 3, 'o': 3, 's': 3, 'v': 3, 'z': 3
}

MATRIX_LETTER = {
    (1, 1): 'q', (1, 2): 'a', (1, 3): 'd',
    (2, 1): 'g', (2, 2): 'j', (2, 3): 'm',
    (3, 1): 'p', (3, 2): 't', (3, 3): 'x'
}

MATRIX_DIGIT = {
    (1, 1): '1', (1, 2): '2', (1, 3): '3',
    (2, 1): '4', (2, 2): '5', (2, 3): '6',
    (3, 1): '7', (3, 2): '8', (3, 3): '9'
}

def calc_6key(codes_4):
    c1, c2, c3, c4 = codes_4
    g1, g2, g3, g4 = CHAR_GROUPS[c1], CHAR_GROUPS[c2], CHAR_GROUPS[c3], CHAR_GROUPS[c4]
    
    sel1_let = MATRIX_LETTER[(g1, g2)]
    sel2_let = MATRIX_LETTER[(g3, g4)]
    lcode_6 = f"{KEY_TO_LETTER[c1]}{KEY_TO_LETTER[c2]}{sel1_let}{KEY_TO_LETTER[c3]}{KEY_TO_LETTER[c4]}{sel2_let}"
    
    sel1_dig = MATRIX_DIGIT[(g1, g2)]
    sel2_dig = MATRIX_DIGIT[(g3, g4)]
    dcode_6 = f"{KEY_TO_DIGIT[c1]}{KEY_TO_DIGIT[c2]}{sel1_dig}{KEY_TO_DIGIT[c3]}{KEY_TO_DIGIT[c4]}{sel2_dig}"
    return lcode_6, dcode_6

def load_char_codes(tigress_path):
    chars = {}
    with open(tigress_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('-') or line.startswith('.'):
                continue
            parts = line.split('\t')
            if len(parts) >= 3 and len(parts[0]) == 1:
                char = parts[0]
                code = parts[2]
                if char not in chars and code.isalpha():
                    chars[char] = code[0].lower()
    return chars

def load_word_weights(jichu_path):
    weights = {}
    top_4_words = []
    with open(jichu_path, 'r', encoding='utf-8') as f:
        for line in f:
            if '\t' in line:
                parts = line.strip().split('\t')
                word = parts[0]
                try:
                    w = int(parts[1])
                except (ValueError, IndexError):
                    w = 10
                weights[word] = w
                if len(word) == 4 and not word.startswith('#'):
                    top_4_words.append((word, w))
    top_4_words.sort(key=lambda x: x[1], reverse=True)
    return weights, top_4_words

def load_idioms(chengyu_path):
    idioms = set()
    with open(chengyu_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) >= 2:
                phrase_raw = parts[1]
                for p in phrase_raw.split('|'):
                    p = p.strip()
                    if len(p) == 4:
                        idioms.add(p)
    return idioms

def load_two_char_words(tigress_ci_paths, min_weight=300):
    """Load high-frequency 2-character words with their 4-letter tiger codes."""
    two_words = {}
    target_path = None
    for p in tigress_ci_paths:
        if os.path.isfile(p):
            target_path = p
            break
    if not target_path:
        print("Warning: tigress_ci dict not found for 2-char words!")
        return two_words

    print(f"Loading 2-character words from {target_path} (min_weight={min_weight})...")
    with open(target_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('.'):
                continue
            parts = line.split('\t')
            if len(parts) >= 3 and len(parts[0]) == 2:
                word = parts[0]
                code = parts[1].strip()
                try:
                    weight = int(parts[2])
                except (ValueError, IndexError):
                    weight = 100
                if len(code) == 4 and code.isalpha() and weight >= min_weight:
                    if word not in two_words or weight > two_words[word][1]:
                        two_words[word] = (code.lower(), weight)
    print(f"Loaded {len(two_words)} high-frequency 2-char words.")
    return two_words

def load_three_char_words(tigress_ci_paths, min_weight=150):
    """Load high-frequency 3-character words with their 4-letter tiger codes (AaBaCaCb)."""
    three_words = {}
    target_path = None
    for p in tigress_ci_paths:
        if os.path.isfile(p):
            target_path = p
            break
    if not target_path:
        print("Warning: tigress_ci dict not found for 3-char words!")
        return three_words

    print(f"Loading 3-character words from {target_path} (min_weight={min_weight})...")
    with open(target_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('.'):
                continue
            parts = line.split('\t')
            if len(parts) >= 3 and len(parts[0]) == 3:
                word = parts[0]
                code = parts[1].strip()
                try:
                    weight = int(parts[2])
                except (ValueError, IndexError):
                    weight = 100
                if len(code) == 4 and code.isalpha() and weight >= min_weight:
                    if word not in three_words or weight > three_words[word][1]:
                        three_words[word] = (code.lower(), weight)
    print(f"Loaded {len(three_words)} high-frequency 3-char words.")
    return three_words

def main():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tigress_path = os.path.join(base_dir, 'tigress.dict.yaml')
    jichu_path = os.path.join(base_dir, 'zuci', 'jichu.pro.dict.yaml')
    chengyu_path = os.path.join(base_dir, 'lua', 'data', 'chengyu.txt')
    output_path = os.path.join(base_dir, 'lua', 'data', '9jianhu_words.tsv')
    lua_data_path = os.path.join(base_dir, 'lua', 'data', '9jianhu_words_data.lua')

    tigress_ci_candidates = [
        os.path.join(base_dir, 'cn_dicts_tiger', 'tigress', 'tigress_ci.dict.yaml'),
        os.path.join(base_dir, 'tiger_dicts', 'tigress', 'tigress_ci.dict.yaml'),
        os.path.expanduser('~/.local/share/fcitx5/rime/tiger_dicts/tigress/tigress_ci.dict.yaml')
    ]

    print("Loading single character first codes...")
    char_codes = load_char_codes(tigress_path)
    print(f"Loaded {len(char_codes)} single characters.")

    print("Loading word weights...")
    word_weights, top_4_words = load_word_weights(jichu_path)

    print("Loading idioms...")
    idioms = load_idioms(chengyu_path)

    target_4_words = {}
    for idiom in idioms:
        # Baseline weight of 100 if not in jichu
        target_4_words[idiom] = word_weights.get(idiom, 100)

    added_common = 0
    for w, weight in top_4_words:
        if w not in target_4_words and re.match(r'^[\u4e00-\u9fa5]{4}$', w):
            target_4_words[w] = weight
            added_common += 1
            if added_common >= 3500:
                break

    # Buckets: stores 3-key, 4-key, 5-key, 6-key codes in both letters and digits
    bucket = defaultdict(list)

    # 1. Encode 4-character words (idioms + top 4-char phrases)
    count_4 = 0
    for word, weight in target_4_words.items():
        codes = [char_codes.get(c) for c in word]
        if any(c is None or c not in KEY_TO_LETTER for c in codes):
            continue

        # Letter format
        lk1, lk2, lk3, lk4 = [KEY_TO_LETTER[c] for c in codes]
        lpos1 = POS_TO_LETTER[codes[0]]
        lcode_4 = f"{lk1}{lk2}{lk3}{lk4}"
        lcode_5 = f"{lcode_4}{lpos1}"

        bucket[lcode_4].append((word, weight))
        bucket[lcode_5].append((word, weight))

        # Digit format
        dk1, dk2, dk3, dk4 = [KEY_TO_DIGIT[c] for c in codes]
        dpos1 = POS_TO_DIGIT[codes[0]]
        dcode_4 = f"{dk1}{dk2}{dk3}{dk4}"
        dcode_5 = f"{dcode_4}{dpos1}"

        bucket[dcode_4].append((word, weight))
        bucket[dcode_5].append((word, weight))

        count_4 += 1

    print(f"Encoded {count_4} four-character words.")

    # 2. Encode 2-character high-frequency words
    two_words = load_two_char_words(tigress_ci_candidates, min_weight=900)
    count_2 = 0
    for word, (code, weight) in two_words.items():
        if any(c not in KEY_TO_LETTER for c in code):
            continue

        # Letter format
        lk1, lk2, lk3, lk4 = [KEY_TO_LETTER[c] for c in code]
        lpos1 = POS_TO_LETTER[code[0]]
        lcode_4 = f"{lk1}{lk2}{lk3}{lk4}"
        lcode_5 = f"{lcode_4}{lpos1}"

        bucket[lcode_4].append((word, weight))
        bucket[lcode_5].append((word, weight))

        # Digit format
        dk1, dk2, dk3, dk4 = [KEY_TO_DIGIT[c] for c in code]
        dpos1 = POS_TO_DIGIT[code[0]]
        dcode_4 = f"{dk1}{dk2}{dk3}{dk4}"
        dcode_5 = f"{dcode_4}{dpos1}"

        bucket[dcode_4].append((word, weight))
        bucket[dcode_5].append((word, weight))

        count_2 += 1

    print(f"Encoded {count_2} two-character words into buckets.")

    # 3. Encode 3-character high-frequency words
    three_words = load_three_char_words(tigress_ci_candidates, min_weight=500)
    count_3 = 0
    count_3_top = 0
    for word, (code, weight) in three_words.items():
        if any(c not in KEY_TO_LETTER for c in code):
            continue

        # Letter format
        lk1, lk2, lk3, lk4 = [KEY_TO_LETTER[c] for c in code]
        lpos1 = POS_TO_LETTER[code[0]]
        lcode_4 = f"{lk1}{lk2}{lk3}{lk4}"
        lcode_5 = f"{lcode_4}{lpos1}"

        bucket[lcode_4].append((word, weight))
        bucket[lcode_5].append((word, weight))

        # Digit format
        dk1, dk2, dk3, dk4 = [KEY_TO_DIGIT[c] for c in code]
        dpos1 = POS_TO_DIGIT[code[0]]
        dcode_4 = f"{dk1}{dk2}{dk3}{dk4}"
        dcode_5 = f"{dcode_4}{dpos1}"

        bucket[dcode_4].append((word, weight))
        bucket[dcode_5].append((word, weight))

        # For Top words (weight >= 500), also generate 3-key natural flow
        lcode_3 = f"{lk1}{lk2}{lk3}"
        dcode_3 = f"{dk1}{dk2}{dk3}"
        bucket[lcode_3].append((word, weight))
        bucket[dcode_3].append((word, weight))
        count_3_top += 1

        count_3 += 1

    print(f"Encoded {count_3} three-character words (including {count_3_top} 3-key top words).")
    print(f"Total buckets: {len(bucket)}.")

    # Write TSV
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        for code, entries in sorted(bucket.items()):
            seen = set()
            words_sorted = []
            entries_sorted = sorted(entries, key=lambda x: x[1], reverse=True)
            
            if len(code) == 3:
                # 3-key bucket: only take top 2 high-frequency words to avoid cluttering single-char candidates
                for w, _ in entries_sorted:
                    if w not in seen:
                        seen.add(w)
                        words_sorted.append(w)
                        if len(words_sorted) >= 2:
                            break
            else:
                # 4-key / 5-key / 6-key bucket: take top 5
                for w, _ in entries_sorted:
                    if w not in seen:
                        seen.add(w)
                        words_sorted.append(w)
                        if len(words_sorted) >= 5:
                            break
            
            f.write(f"{code}\t{' '.join(words_sorted)}\n")

    size_kb = os.path.getsize(output_path) / 1024
    print(f"Written TSV to {output_path} ({size_kb:.1f} KB).")

    # Also write fallback Lua data module for Android sandboxing
    print(f"Generating fallback Lua data module {lua_data_path}...")
    with open(lua_data_path, 'w', encoding='utf-8') as f:
        f.write("-- Auto-generated 9jianhu words fallback table\n")
        f.write("local M = {\n")
        with open(output_path, 'r', encoding='utf-8') as tf:
            for line in tf:
                line = line.strip()
                if not line:
                    continue
                parts = line.split('\t')
                code = parts[0]
                words = parts[1].split(' ')
                words_quoted = [f'"{w}"' for w in words]
                f.write(f'  ["{code}"] = {{{", ".join(words_quoted)}}},\n')
        f.write("}\nreturn M\n")

    lua_size_kb = os.path.getsize(lua_data_path) / 1024
    print(f"Written Lua fallback to {lua_data_path} ({lua_size_kb:.1f} KB).")

if __name__ == '__main__':
    main()
