/// One element of an XML document: its name without a namespace prefix,
/// its attributes, its child elements and the text directly inside it.
class XmlNode {
  XmlNode(this.name, this.attributes);

  final String name;
  final Map<String, String> attributes;
  final children = <XmlNode>[];
  final _text = StringBuffer();

  /// The text directly inside this element, without its children's.
  String get text => _text.toString();

  String? operator [](String attribute) => attributes[attribute];

  /// The first child named [name], or null.
  XmlNode? child(String name) {
    for (final c in children) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// Every child named [name].
  Iterable<XmlNode> all(String name) => children.where((c) => c.name == name);

  /// Follows child names from this element; null where one is missing.
  XmlNode? path(List<String> names) {
    XmlNode? at = this;
    for (final n in names) {
      at = at?.child(n);
    }
    return at;
  }

  /// This element and everything inside it, parents first.
  Iterable<XmlNode> get descendants sync* {
    yield this;
    for (final c in children) {
      yield* c.descendants;
    }
  }
}

/// Reads the element tree of an XML document: elements, attributes, text
/// and CDATA; the five named entities and numeric ones. Comments,
/// processing instructions and the DOCTYPE are skipped. Just enough for
/// data files (COLLADA); it doesn't validate.
///
/// Throws a [FormatException] when the document isn't well formed.
XmlNode parseXml(String source) {
  final root = XmlNode('', const {});
  final stack = [root];
  var at = 0;
  final length = source.length;

  Never bad(String what) => throw FormatException('XML: $what', source, at);

  while (at < length) {
    final lt = source.indexOf('<', at);
    if (lt < 0) break;
    if (lt > at && stack.length > 1) {
      stack.last._text.write(_unescape(source.substring(at, lt)));
    }
    at = lt;
    if (source.startsWith('<!--', at)) {
      final end = source.indexOf('-->', at + 4);
      if (end < 0) bad('comment not closed');
      at = end + 3;
    } else if (source.startsWith('<![CDATA[', at)) {
      final end = source.indexOf(']]>', at + 9);
      if (end < 0) bad('CDATA not closed');
      stack.last._text.write(source.substring(at + 9, end));
      at = end + 3;
    } else if (source.startsWith('<?', at)) {
      final end = source.indexOf('?>', at + 2);
      if (end < 0) bad('instruction not closed');
      at = end + 2;
    } else if (source.startsWith('<!', at)) {
      // DOCTYPE, with an optional [internal subset].
      var depth = 0;
      var end = at + 2;
      for (; end < length; end++) {
        final c = source.codeUnitAt(end);
        if (c == 0x5B) depth++;
        if (c == 0x5D) depth--;
        if (c == 0x3E && depth <= 0) break;
      }
      at = end + 1;
    } else if (source.startsWith('</', at)) {
      final end = source.indexOf('>', at + 2);
      if (end < 0) bad('tag not closed');
      if (stack.length < 2) bad('closing tag without an opening one');
      stack.removeLast();
      at = end + 1;
    } else {
      // <name attr="value" …> or <name … />
      var i = at + 1;
      bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
      final nameStart = i;
      while (i < length) {
        final c = source.codeUnitAt(i);
        if (isSpace(c) || c == 0x2F || c == 0x3E) break;
        i++;
      }
      if (i == nameStart) bad('tag without a name');
      final attributes = <String, String>{};
      var selfClosing = false;
      while (true) {
        while (i < length && isSpace(source.codeUnitAt(i))) {
          i++;
        }
        if (i >= length) bad('tag not closed');
        final c = source.codeUnitAt(i);
        if (c == 0x3E) {
          i++;
          break;
        }
        if (c == 0x2F) {
          selfClosing = true;
          i++;
          continue;
        }
        final keyStart = i;
        while (i < length) {
          final k = source.codeUnitAt(i);
          if (k == 0x3D || isSpace(k) || k == 0x3E || k == 0x2F) break;
          i++;
        }
        final key = source.substring(keyStart, i);
        while (i < length && isSpace(source.codeUnitAt(i))) {
          i++;
        }
        if (i >= length || source.codeUnitAt(i) != 0x3D) {
          bad('attribute without a value');
        }
        i++;
        while (i < length && isSpace(source.codeUnitAt(i))) {
          i++;
        }
        if (i >= length) bad('tag not closed');
        final quote = source.codeUnitAt(i);
        if (quote != 0x22 && quote != 0x27) bad('attribute value not quoted');
        final close = source.indexOf(String.fromCharCode(quote), i + 1);
        if (close < 0) bad('attribute value not closed');
        attributes[_local(key)] = _unescape(source.substring(i + 1, close));
        i = close + 1;
      }
      final node = XmlNode(
        _local(source.substring(nameStart, _nameEnd(source, nameStart))),
        attributes,
      );
      stack.last.children.add(node);
      if (!selfClosing) stack.add(node);
      at = i;
    }
  }
  if (stack.length != 1) {
    throw FormatException('XML: <${stack.last.name}> not closed');
  }
  if (root.children.length != 1) {
    throw const FormatException('XML: one root element expected');
  }
  return root.children.single;
}

int _nameEnd(String source, int start) {
  var i = start;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c == 0x20 ||
        c == 0x09 ||
        c == 0x0A ||
        c == 0x0D ||
        c == 0x2F ||
        c == 0x3E) {
      break;
    }
    i++;
  }
  return i;
}

/// A name without its namespace prefix (`xsi:type` → `type`).
String _local(String name) {
  final colon = name.indexOf(':');
  return colon < 0 ? name : name.substring(colon + 1);
}

final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

String _unescape(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entity, (m) {
    final e = m[1]!;
    if (e.startsWith('#x')) {
      return String.fromCharCode(int.parse(e.substring(2), radix: 16));
    }
    if (e.startsWith('#')) {
      return String.fromCharCode(int.parse(e.substring(1)));
    }
    return switch (e) {
      'lt' => '<',
      'gt' => '>',
      'amp' => '&',
      'quot' => '"',
      'apos' => "'",
      _ => m[0]!,
    };
  });
}
