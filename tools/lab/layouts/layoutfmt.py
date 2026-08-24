import json, collections

def num(v):
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, float):
        if v == int(v) and abs(v) < 1e15:
            # house style keeps -0.0 and 0.0 rather than 0
            s = ('%g' % v)
            if s in ('-0','0'): return '-0.0' if str(v).startswith('-') else '0.0'
            return s
        return repr(round(v, 6)).rstrip('0').rstrip('.') if '.' in repr(v) else repr(v)
    return json.dumps(v)

def inline_obj(o):
    return '{' + ', '.join('%s: %s' % (json.dumps(k), num(v)) for k, v in o.items()) + '}'

def inline_arr(a):
    return '[' + ', '.join(num(v) for v in a) + ']'

def emit(d):
    L = ['{']
    keys = list(d.keys())
    for ki, k in enumerate(keys):
        v = d[k]
        tail = ',' if ki < len(keys) - 1 else ''
        if isinstance(v, list) and v and isinstance(v[0], dict):
            L.append(' %s: [' % json.dumps(k))
            for ii, item in enumerate(v):
                L.append('  {')
                ik = list(item.keys())
                for jj, k2 in enumerate(ik):
                    v2 = item[k2]
                    t2 = ',' if jj < len(ik) - 1 else ''
                    if isinstance(v2, dict):
                        L.append('   %s: %s%s' % (json.dumps(k2), inline_obj(v2), t2))
                    elif isinstance(v2, list):
                        L.append('   %s: %s%s' % (json.dumps(k2), inline_arr(v2), t2))
                    else:
                        L.append('   %s: %s%s' % (json.dumps(k2), num(v2), t2))
                L.append('  }' + (',' if ii < len(v) - 1 else ''))
            L.append(' ]' + tail)
        else:
            L.append(' %s: %s%s' % (json.dumps(k), num(v), tail))
    L.append('}')
    return '\n'.join(L) + '\n'

def load(f):
    return json.load(open(f, encoding='utf-8'), object_pairs_hook=collections.OrderedDict)

def save(f, d):
    open(f, 'w', encoding='utf-8').write(emit(d))
