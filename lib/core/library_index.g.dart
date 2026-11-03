// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'library_index.dart';

// ignore_for_file: type=lint
class $PacksTable extends Packs with TableInfo<$PacksTable, PackRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PacksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
    'author',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _authorUrlMeta = const VerificationMeta(
    'authorUrl',
  );
  @override
  late final GeneratedColumn<String> authorUrl = GeneratedColumn<String>(
    'author_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isContainerMeta = const VerificationMeta(
    'isContainer',
  );
  @override
  late final GeneratedColumn<bool> isContainer = GeneratedColumn<bool>(
    'is_container',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_container" IN (0, 1))',
    ),
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String> types =
      GeneratedColumn<String>(
        'types',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<List<String>>($PacksTable.$convertertypes);
  @override
  late final GeneratedColumnWithTypeConverter<List<String>, String> tags =
      GeneratedColumn<String>(
        'tags',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<List<String>>($PacksTable.$convertertags);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _previewMeta = const VerificationMeta(
    'preview',
  );
  @override
  late final GeneratedColumn<String> preview = GeneratedColumn<String>(
    'preview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileCountMeta = const VerificationMeta(
    'fileCount',
  );
  @override
  late final GeneratedColumn<int> fileCount = GeneratedColumn<int>(
    'file_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _totalBytesMeta = const VerificationMeta(
    'totalBytes',
  );
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
    'total_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    path,
    title,
    author,
    authorUrl,
    parentId,
    isContainer,
    types,
    tags,
    source,
    preview,
    fileCount,
    totalBytes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'packs';
  @override
  VerificationContext validateIntegrity(
    Insertable<PackRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('author')) {
      context.handle(
        _authorMeta,
        author.isAcceptableOrUnknown(data['author']!, _authorMeta),
      );
    }
    if (data.containsKey('author_url')) {
      context.handle(
        _authorUrlMeta,
        authorUrl.isAcceptableOrUnknown(data['author_url']!, _authorUrlMeta),
      );
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('is_container')) {
      context.handle(
        _isContainerMeta,
        isContainer.isAcceptableOrUnknown(
          data['is_container']!,
          _isContainerMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_isContainerMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('preview')) {
      context.handle(
        _previewMeta,
        preview.isAcceptableOrUnknown(data['preview']!, _previewMeta),
      );
    }
    if (data.containsKey('file_count')) {
      context.handle(
        _fileCountMeta,
        fileCount.isAcceptableOrUnknown(data['file_count']!, _fileCountMeta),
      );
    } else if (isInserting) {
      context.missing(_fileCountMeta);
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
        _totalBytesMeta,
        totalBytes.isAcceptableOrUnknown(data['total_bytes']!, _totalBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_totalBytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PackRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PackRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      author: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author'],
      ),
      authorUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_url'],
      ),
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      isContainer: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_container'],
      )!,
      types: $PacksTable.$convertertypes.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}types'],
        )!,
      ),
      tags: $PacksTable.$convertertags.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}tags'],
        )!,
      ),
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      ),
      preview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}preview'],
      ),
      fileCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_count'],
      )!,
      totalBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_bytes'],
      )!,
    );
  }

  @override
  $PacksTable createAlias(String alias) {
    return $PacksTable(attachedDatabase, alias);
  }

  static TypeConverter<List<String>, String> $convertertypes =
      const StringListConverter();
  static TypeConverter<List<String>, String> $convertertags =
      const StringListConverter();
}

class PackRow extends DataClass implements Insertable<PackRow> {
  final String id;
  final String path;
  final String title;
  final String? author;
  final String? authorUrl;
  final String? parentId;
  final bool isContainer;
  final List<String> types;
  final List<String> tags;
  final String? source;

  /// Preview image relative to [path].
  final String? preview;
  final int fileCount;
  final int totalBytes;
  const PackRow({
    required this.id,
    required this.path,
    required this.title,
    this.author,
    this.authorUrl,
    this.parentId,
    required this.isContainer,
    required this.types,
    required this.tags,
    this.source,
    this.preview,
    required this.fileCount,
    required this.totalBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['path'] = Variable<String>(path);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || author != null) {
      map['author'] = Variable<String>(author);
    }
    if (!nullToAbsent || authorUrl != null) {
      map['author_url'] = Variable<String>(authorUrl);
    }
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['is_container'] = Variable<bool>(isContainer);
    {
      map['types'] = Variable<String>($PacksTable.$convertertypes.toSql(types));
    }
    {
      map['tags'] = Variable<String>($PacksTable.$convertertags.toSql(tags));
    }
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    if (!nullToAbsent || preview != null) {
      map['preview'] = Variable<String>(preview);
    }
    map['file_count'] = Variable<int>(fileCount);
    map['total_bytes'] = Variable<int>(totalBytes);
    return map;
  }

  PacksCompanion toCompanion(bool nullToAbsent) {
    return PacksCompanion(
      id: Value(id),
      path: Value(path),
      title: Value(title),
      author: author == null && nullToAbsent
          ? const Value.absent()
          : Value(author),
      authorUrl: authorUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(authorUrl),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      isContainer: Value(isContainer),
      types: Value(types),
      tags: Value(tags),
      source: source == null && nullToAbsent
          ? const Value.absent()
          : Value(source),
      preview: preview == null && nullToAbsent
          ? const Value.absent()
          : Value(preview),
      fileCount: Value(fileCount),
      totalBytes: Value(totalBytes),
    );
  }

  factory PackRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PackRow(
      id: serializer.fromJson<String>(json['id']),
      path: serializer.fromJson<String>(json['path']),
      title: serializer.fromJson<String>(json['title']),
      author: serializer.fromJson<String?>(json['author']),
      authorUrl: serializer.fromJson<String?>(json['authorUrl']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      isContainer: serializer.fromJson<bool>(json['isContainer']),
      types: serializer.fromJson<List<String>>(json['types']),
      tags: serializer.fromJson<List<String>>(json['tags']),
      source: serializer.fromJson<String?>(json['source']),
      preview: serializer.fromJson<String?>(json['preview']),
      fileCount: serializer.fromJson<int>(json['fileCount']),
      totalBytes: serializer.fromJson<int>(json['totalBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'path': serializer.toJson<String>(path),
      'title': serializer.toJson<String>(title),
      'author': serializer.toJson<String?>(author),
      'authorUrl': serializer.toJson<String?>(authorUrl),
      'parentId': serializer.toJson<String?>(parentId),
      'isContainer': serializer.toJson<bool>(isContainer),
      'types': serializer.toJson<List<String>>(types),
      'tags': serializer.toJson<List<String>>(tags),
      'source': serializer.toJson<String?>(source),
      'preview': serializer.toJson<String?>(preview),
      'fileCount': serializer.toJson<int>(fileCount),
      'totalBytes': serializer.toJson<int>(totalBytes),
    };
  }

  PackRow copyWith({
    String? id,
    String? path,
    String? title,
    Value<String?> author = const Value.absent(),
    Value<String?> authorUrl = const Value.absent(),
    Value<String?> parentId = const Value.absent(),
    bool? isContainer,
    List<String>? types,
    List<String>? tags,
    Value<String?> source = const Value.absent(),
    Value<String?> preview = const Value.absent(),
    int? fileCount,
    int? totalBytes,
  }) => PackRow(
    id: id ?? this.id,
    path: path ?? this.path,
    title: title ?? this.title,
    author: author.present ? author.value : this.author,
    authorUrl: authorUrl.present ? authorUrl.value : this.authorUrl,
    parentId: parentId.present ? parentId.value : this.parentId,
    isContainer: isContainer ?? this.isContainer,
    types: types ?? this.types,
    tags: tags ?? this.tags,
    source: source.present ? source.value : this.source,
    preview: preview.present ? preview.value : this.preview,
    fileCount: fileCount ?? this.fileCount,
    totalBytes: totalBytes ?? this.totalBytes,
  );
  PackRow copyWithCompanion(PacksCompanion data) {
    return PackRow(
      id: data.id.present ? data.id.value : this.id,
      path: data.path.present ? data.path.value : this.path,
      title: data.title.present ? data.title.value : this.title,
      author: data.author.present ? data.author.value : this.author,
      authorUrl: data.authorUrl.present ? data.authorUrl.value : this.authorUrl,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      isContainer: data.isContainer.present
          ? data.isContainer.value
          : this.isContainer,
      types: data.types.present ? data.types.value : this.types,
      tags: data.tags.present ? data.tags.value : this.tags,
      source: data.source.present ? data.source.value : this.source,
      preview: data.preview.present ? data.preview.value : this.preview,
      fileCount: data.fileCount.present ? data.fileCount.value : this.fileCount,
      totalBytes: data.totalBytes.present
          ? data.totalBytes.value
          : this.totalBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PackRow(')
          ..write('id: $id, ')
          ..write('path: $path, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('authorUrl: $authorUrl, ')
          ..write('parentId: $parentId, ')
          ..write('isContainer: $isContainer, ')
          ..write('types: $types, ')
          ..write('tags: $tags, ')
          ..write('source: $source, ')
          ..write('preview: $preview, ')
          ..write('fileCount: $fileCount, ')
          ..write('totalBytes: $totalBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    path,
    title,
    author,
    authorUrl,
    parentId,
    isContainer,
    types,
    tags,
    source,
    preview,
    fileCount,
    totalBytes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PackRow &&
          other.id == this.id &&
          other.path == this.path &&
          other.title == this.title &&
          other.author == this.author &&
          other.authorUrl == this.authorUrl &&
          other.parentId == this.parentId &&
          other.isContainer == this.isContainer &&
          other.types == this.types &&
          other.tags == this.tags &&
          other.source == this.source &&
          other.preview == this.preview &&
          other.fileCount == this.fileCount &&
          other.totalBytes == this.totalBytes);
}

class PacksCompanion extends UpdateCompanion<PackRow> {
  final Value<String> id;
  final Value<String> path;
  final Value<String> title;
  final Value<String?> author;
  final Value<String?> authorUrl;
  final Value<String?> parentId;
  final Value<bool> isContainer;
  final Value<List<String>> types;
  final Value<List<String>> tags;
  final Value<String?> source;
  final Value<String?> preview;
  final Value<int> fileCount;
  final Value<int> totalBytes;
  final Value<int> rowid;
  const PacksCompanion({
    this.id = const Value.absent(),
    this.path = const Value.absent(),
    this.title = const Value.absent(),
    this.author = const Value.absent(),
    this.authorUrl = const Value.absent(),
    this.parentId = const Value.absent(),
    this.isContainer = const Value.absent(),
    this.types = const Value.absent(),
    this.tags = const Value.absent(),
    this.source = const Value.absent(),
    this.preview = const Value.absent(),
    this.fileCount = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PacksCompanion.insert({
    required String id,
    required String path,
    required String title,
    this.author = const Value.absent(),
    this.authorUrl = const Value.absent(),
    this.parentId = const Value.absent(),
    required bool isContainer,
    required List<String> types,
    required List<String> tags,
    this.source = const Value.absent(),
    this.preview = const Value.absent(),
    required int fileCount,
    required int totalBytes,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       path = Value(path),
       title = Value(title),
       isContainer = Value(isContainer),
       types = Value(types),
       tags = Value(tags),
       fileCount = Value(fileCount),
       totalBytes = Value(totalBytes);
  static Insertable<PackRow> custom({
    Expression<String>? id,
    Expression<String>? path,
    Expression<String>? title,
    Expression<String>? author,
    Expression<String>? authorUrl,
    Expression<String>? parentId,
    Expression<bool>? isContainer,
    Expression<String>? types,
    Expression<String>? tags,
    Expression<String>? source,
    Expression<String>? preview,
    Expression<int>? fileCount,
    Expression<int>? totalBytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (path != null) 'path': path,
      if (title != null) 'title': title,
      if (author != null) 'author': author,
      if (authorUrl != null) 'author_url': authorUrl,
      if (parentId != null) 'parent_id': parentId,
      if (isContainer != null) 'is_container': isContainer,
      if (types != null) 'types': types,
      if (tags != null) 'tags': tags,
      if (source != null) 'source': source,
      if (preview != null) 'preview': preview,
      if (fileCount != null) 'file_count': fileCount,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PacksCompanion copyWith({
    Value<String>? id,
    Value<String>? path,
    Value<String>? title,
    Value<String?>? author,
    Value<String?>? authorUrl,
    Value<String?>? parentId,
    Value<bool>? isContainer,
    Value<List<String>>? types,
    Value<List<String>>? tags,
    Value<String?>? source,
    Value<String?>? preview,
    Value<int>? fileCount,
    Value<int>? totalBytes,
    Value<int>? rowid,
  }) {
    return PacksCompanion(
      id: id ?? this.id,
      path: path ?? this.path,
      title: title ?? this.title,
      author: author ?? this.author,
      authorUrl: authorUrl ?? this.authorUrl,
      parentId: parentId ?? this.parentId,
      isContainer: isContainer ?? this.isContainer,
      types: types ?? this.types,
      tags: tags ?? this.tags,
      source: source ?? this.source,
      preview: preview ?? this.preview,
      fileCount: fileCount ?? this.fileCount,
      totalBytes: totalBytes ?? this.totalBytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (authorUrl.present) {
      map['author_url'] = Variable<String>(authorUrl.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (isContainer.present) {
      map['is_container'] = Variable<bool>(isContainer.value);
    }
    if (types.present) {
      map['types'] = Variable<String>(
        $PacksTable.$convertertypes.toSql(types.value),
      );
    }
    if (tags.present) {
      map['tags'] = Variable<String>(
        $PacksTable.$convertertags.toSql(tags.value),
      );
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (preview.present) {
      map['preview'] = Variable<String>(preview.value);
    }
    if (fileCount.present) {
      map['file_count'] = Variable<int>(fileCount.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PacksCompanion(')
          ..write('id: $id, ')
          ..write('path: $path, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('authorUrl: $authorUrl, ')
          ..write('parentId: $parentId, ')
          ..write('isContainer: $isContainer, ')
          ..write('types: $types, ')
          ..write('tags: $tags, ')
          ..write('source: $source, ')
          ..write('preview: $preview, ')
          ..write('fileCount: $fileCount, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PackFilesTable extends PackFiles
    with TableInfo<$PackFilesTable, PackFile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PackFilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _packIdMeta = const VerificationMeta('packId');
  @override
  late final GeneratedColumn<String> packId = GeneratedColumn<String>(
    'pack_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _relPathMeta = const VerificationMeta(
    'relPath',
  );
  @override
  late final GeneratedColumn<String> relPath = GeneratedColumn<String>(
    'rel_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [packId, relPath, size];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pack_files';
  @override
  VerificationContext validateIntegrity(
    Insertable<PackFile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('pack_id')) {
      context.handle(
        _packIdMeta,
        packId.isAcceptableOrUnknown(data['pack_id']!, _packIdMeta),
      );
    } else if (isInserting) {
      context.missing(_packIdMeta);
    }
    if (data.containsKey('rel_path')) {
      context.handle(
        _relPathMeta,
        relPath.isAcceptableOrUnknown(data['rel_path']!, _relPathMeta),
      );
    } else if (isInserting) {
      context.missing(_relPathMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {packId, relPath};
  @override
  PackFile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PackFile(
      packId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pack_id'],
      )!,
      relPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rel_path'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
    );
  }

  @override
  $PackFilesTable createAlias(String alias) {
    return $PackFilesTable(attachedDatabase, alias);
  }
}

class PackFile extends DataClass implements Insertable<PackFile> {
  final String packId;
  final String relPath;
  final int size;
  const PackFile({
    required this.packId,
    required this.relPath,
    required this.size,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['pack_id'] = Variable<String>(packId);
    map['rel_path'] = Variable<String>(relPath);
    map['size'] = Variable<int>(size);
    return map;
  }

  PackFilesCompanion toCompanion(bool nullToAbsent) {
    return PackFilesCompanion(
      packId: Value(packId),
      relPath: Value(relPath),
      size: Value(size),
    );
  }

  factory PackFile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PackFile(
      packId: serializer.fromJson<String>(json['packId']),
      relPath: serializer.fromJson<String>(json['relPath']),
      size: serializer.fromJson<int>(json['size']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'packId': serializer.toJson<String>(packId),
      'relPath': serializer.toJson<String>(relPath),
      'size': serializer.toJson<int>(size),
    };
  }

  PackFile copyWith({String? packId, String? relPath, int? size}) => PackFile(
    packId: packId ?? this.packId,
    relPath: relPath ?? this.relPath,
    size: size ?? this.size,
  );
  PackFile copyWithCompanion(PackFilesCompanion data) {
    return PackFile(
      packId: data.packId.present ? data.packId.value : this.packId,
      relPath: data.relPath.present ? data.relPath.value : this.relPath,
      size: data.size.present ? data.size.value : this.size,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PackFile(')
          ..write('packId: $packId, ')
          ..write('relPath: $relPath, ')
          ..write('size: $size')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(packId, relPath, size);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PackFile &&
          other.packId == this.packId &&
          other.relPath == this.relPath &&
          other.size == this.size);
}

class PackFilesCompanion extends UpdateCompanion<PackFile> {
  final Value<String> packId;
  final Value<String> relPath;
  final Value<int> size;
  final Value<int> rowid;
  const PackFilesCompanion({
    this.packId = const Value.absent(),
    this.relPath = const Value.absent(),
    this.size = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PackFilesCompanion.insert({
    required String packId,
    required String relPath,
    required int size,
    this.rowid = const Value.absent(),
  }) : packId = Value(packId),
       relPath = Value(relPath),
       size = Value(size);
  static Insertable<PackFile> custom({
    Expression<String>? packId,
    Expression<String>? relPath,
    Expression<int>? size,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (packId != null) 'pack_id': packId,
      if (relPath != null) 'rel_path': relPath,
      if (size != null) 'size': size,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PackFilesCompanion copyWith({
    Value<String>? packId,
    Value<String>? relPath,
    Value<int>? size,
    Value<int>? rowid,
  }) {
    return PackFilesCompanion(
      packId: packId ?? this.packId,
      relPath: relPath ?? this.relPath,
      size: size ?? this.size,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (packId.present) {
      map['pack_id'] = Variable<String>(packId.value);
    }
    if (relPath.present) {
      map['rel_path'] = Variable<String>(relPath.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PackFilesCompanion(')
          ..write('packId: $packId, ')
          ..write('relPath: $relPath, ')
          ..write('size: $size, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScanStatesTable extends ScanStates
    with TableInfo<$ScanStatesTable, ScanState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScanStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rootMeta = const VerificationMeta('root');
  @override
  late final GeneratedColumn<String> root = GeneratedColumn<String>(
    'root',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scannedAtMeta = const VerificationMeta(
    'scannedAt',
  );
  @override
  late final GeneratedColumn<DateTime> scannedAt = GeneratedColumn<DateTime>(
    'scanned_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [root, fingerprint, scannedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scan_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScanState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('root')) {
      context.handle(
        _rootMeta,
        root.isAcceptableOrUnknown(data['root']!, _rootMeta),
      );
    } else if (isInserting) {
      context.missing(_rootMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('scanned_at')) {
      context.handle(
        _scannedAtMeta,
        scannedAt.isAcceptableOrUnknown(data['scanned_at']!, _scannedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_scannedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {root};
  @override
  ScanState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScanState(
      root: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}root'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      scannedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}scanned_at'],
      )!,
    );
  }

  @override
  $ScanStatesTable createAlias(String alias) {
    return $ScanStatesTable(attachedDatabase, alias);
  }
}

class ScanState extends DataClass implements Insertable<ScanState> {
  final String root;
  final String fingerprint;
  final DateTime scannedAt;
  const ScanState({
    required this.root,
    required this.fingerprint,
    required this.scannedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['root'] = Variable<String>(root);
    map['fingerprint'] = Variable<String>(fingerprint);
    map['scanned_at'] = Variable<DateTime>(scannedAt);
    return map;
  }

  ScanStatesCompanion toCompanion(bool nullToAbsent) {
    return ScanStatesCompanion(
      root: Value(root),
      fingerprint: Value(fingerprint),
      scannedAt: Value(scannedAt),
    );
  }

  factory ScanState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScanState(
      root: serializer.fromJson<String>(json['root']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      scannedAt: serializer.fromJson<DateTime>(json['scannedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'root': serializer.toJson<String>(root),
      'fingerprint': serializer.toJson<String>(fingerprint),
      'scannedAt': serializer.toJson<DateTime>(scannedAt),
    };
  }

  ScanState copyWith({
    String? root,
    String? fingerprint,
    DateTime? scannedAt,
  }) => ScanState(
    root: root ?? this.root,
    fingerprint: fingerprint ?? this.fingerprint,
    scannedAt: scannedAt ?? this.scannedAt,
  );
  ScanState copyWithCompanion(ScanStatesCompanion data) {
    return ScanState(
      root: data.root.present ? data.root.value : this.root,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      scannedAt: data.scannedAt.present ? data.scannedAt.value : this.scannedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScanState(')
          ..write('root: $root, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('scannedAt: $scannedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(root, fingerprint, scannedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScanState &&
          other.root == this.root &&
          other.fingerprint == this.fingerprint &&
          other.scannedAt == this.scannedAt);
}

class ScanStatesCompanion extends UpdateCompanion<ScanState> {
  final Value<String> root;
  final Value<String> fingerprint;
  final Value<DateTime> scannedAt;
  final Value<int> rowid;
  const ScanStatesCompanion({
    this.root = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.scannedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScanStatesCompanion.insert({
    required String root,
    required String fingerprint,
    required DateTime scannedAt,
    this.rowid = const Value.absent(),
  }) : root = Value(root),
       fingerprint = Value(fingerprint),
       scannedAt = Value(scannedAt);
  static Insertable<ScanState> custom({
    Expression<String>? root,
    Expression<String>? fingerprint,
    Expression<DateTime>? scannedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (root != null) 'root': root,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (scannedAt != null) 'scanned_at': scannedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScanStatesCompanion copyWith({
    Value<String>? root,
    Value<String>? fingerprint,
    Value<DateTime>? scannedAt,
    Value<int>? rowid,
  }) {
    return ScanStatesCompanion(
      root: root ?? this.root,
      fingerprint: fingerprint ?? this.fingerprint,
      scannedAt: scannedAt ?? this.scannedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (root.present) {
      map['root'] = Variable<String>(root.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (scannedAt.present) {
      map['scanned_at'] = Variable<DateTime>(scannedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScanStatesCompanion(')
          ..write('root: $root, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('scannedAt: $scannedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LibraryIndex extends GeneratedDatabase {
  _$LibraryIndex(QueryExecutor e) : super(e);
  $LibraryIndexManager get managers => $LibraryIndexManager(this);
  late final $PacksTable packs = $PacksTable(this);
  late final $PackFilesTable packFiles = $PackFilesTable(this);
  late final $ScanStatesTable scanStates = $ScanStatesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    packs,
    packFiles,
    scanStates,
  ];
}

typedef $$PacksTableCreateCompanionBuilder = PacksCompanion Function({
  required String id,
  required String path,
  required String title,
  Value<String?> author,
  Value<String?> authorUrl,
  Value<String?> parentId,
  required bool isContainer,
  required List<String> types,
  required List<String> tags,
  Value<String?> source,
  Value<String?> preview,
  required int fileCount,
  required int totalBytes,
  Value<int> rowid,
});
typedef $$PacksTableUpdateCompanionBuilder = PacksCompanion Function({
  Value<String> id,
  Value<String> path,
  Value<String> title,
  Value<String?> author,
  Value<String?> authorUrl,
  Value<String?> parentId,
  Value<bool> isContainer,
  Value<List<String>> types,
  Value<List<String>> tags,
  Value<String?> source,
  Value<String?> preview,
  Value<int> fileCount,
  Value<int> totalBytes,
  Value<int> rowid,
});

class $$PacksTableFilterComposer extends Composer<_$LibraryIndex, $PacksTable> {
  $$PacksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorUrl => $composableBuilder(
    column: $table.authorUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isContainer => $composableBuilder(
    column: $table.isContainer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String>
  get types => $composableBuilder(
    column: $table.types,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<List<String>, List<String>, String> get tags =>
      $composableBuilder(
        column: $table.tags,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get preview => $composableBuilder(
    column: $table.preview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileCount => $composableBuilder(
    column: $table.fileCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PacksTableOrderingComposer
    extends Composer<_$LibraryIndex, $PacksTable> {
  $$PacksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorUrl => $composableBuilder(
    column: $table.authorUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isContainer => $composableBuilder(
    column: $table.isContainer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get types => $composableBuilder(
    column: $table.types,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get preview => $composableBuilder(
    column: $table.preview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileCount => $composableBuilder(
    column: $table.fileCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PacksTableAnnotationComposer
    extends Composer<_$LibraryIndex, $PacksTable> {
  $$PacksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get authorUrl =>
      $composableBuilder(column: $table.authorUrl, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<bool> get isContainer => $composableBuilder(
    column: $table.isContainer,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<List<String>, String> get types =>
      $composableBuilder(column: $table.types, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<String>, String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get preview =>
      $composableBuilder(column: $table.preview, builder: (column) => column);

  GeneratedColumn<int> get fileCount =>
      $composableBuilder(column: $table.fileCount, builder: (column) => column);

  GeneratedColumn<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => column,
  );
}

class $$PacksTableTableManager
    extends
        RootTableManager<
          _$LibraryIndex,
          $PacksTable,
          PackRow,
          $$PacksTableFilterComposer,
          $$PacksTableOrderingComposer,
          $$PacksTableAnnotationComposer,
          $$PacksTableCreateCompanionBuilder,
          $$PacksTableUpdateCompanionBuilder,
          (PackRow, BaseReferences<_$LibraryIndex, $PacksTable, PackRow>),
          PackRow,
          PrefetchHooks Function()
        > {
  $$PacksTableTableManager(_$LibraryIndex db, $PacksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PacksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PacksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PacksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> author = const Value.absent(),
                Value<String?> authorUrl = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<bool> isContainer = const Value.absent(),
                Value<List<String>> types = const Value.absent(),
                Value<List<String>> tags = const Value.absent(),
                Value<String?> source = const Value.absent(),
                Value<String?> preview = const Value.absent(),
                Value<int> fileCount = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PacksCompanion(
                id: id,
                path: path,
                title: title,
                author: author,
                authorUrl: authorUrl,
                parentId: parentId,
                isContainer: isContainer,
                types: types,
                tags: tags,
                source: source,
                preview: preview,
                fileCount: fileCount,
                totalBytes: totalBytes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String path,
                required String title,
                Value<String?> author = const Value.absent(),
                Value<String?> authorUrl = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                required bool isContainer,
                required List<String> types,
                required List<String> tags,
                Value<String?> source = const Value.absent(),
                Value<String?> preview = const Value.absent(),
                required int fileCount,
                required int totalBytes,
                Value<int> rowid = const Value.absent(),
              }) => PacksCompanion.insert(
                id: id,
                path: path,
                title: title,
                author: author,
                authorUrl: authorUrl,
                parentId: parentId,
                isContainer: isContainer,
                types: types,
                tags: tags,
                source: source,
                preview: preview,
                fileCount: fileCount,
                totalBytes: totalBytes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PacksTable, PackRow>(table),
                  BaseReferences<_$LibraryIndex, $PacksTable, PackRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PacksTableProcessedTableManager =
    ProcessedTableManager<
      _$LibraryIndex,
      $PacksTable,
      PackRow,
      $$PacksTableFilterComposer,
      $$PacksTableOrderingComposer,
      $$PacksTableAnnotationComposer,
      $$PacksTableCreateCompanionBuilder,
      $$PacksTableUpdateCompanionBuilder,
      (PackRow, BaseReferences<_$LibraryIndex, $PacksTable, PackRow>),
      PackRow,
      PrefetchHooks Function()
    >;
typedef $$PackFilesTableCreateCompanionBuilder = PackFilesCompanion Function({
  required String packId,
  required String relPath,
  required int size,
  Value<int> rowid,
});
typedef $$PackFilesTableUpdateCompanionBuilder = PackFilesCompanion Function({
  Value<String> packId,
  Value<String> relPath,
  Value<int> size,
  Value<int> rowid,
});

class $$PackFilesTableFilterComposer
    extends Composer<_$LibraryIndex, $PackFilesTable> {
  $$PackFilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get packId => $composableBuilder(
    column: $table.packId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relPath => $composableBuilder(
    column: $table.relPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PackFilesTableOrderingComposer
    extends Composer<_$LibraryIndex, $PackFilesTable> {
  $$PackFilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get packId => $composableBuilder(
    column: $table.packId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relPath => $composableBuilder(
    column: $table.relPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PackFilesTableAnnotationComposer
    extends Composer<_$LibraryIndex, $PackFilesTable> {
  $$PackFilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get packId =>
      $composableBuilder(column: $table.packId, builder: (column) => column);

  GeneratedColumn<String> get relPath =>
      $composableBuilder(column: $table.relPath, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);
}

class $$PackFilesTableTableManager
    extends
        RootTableManager<
          _$LibraryIndex,
          $PackFilesTable,
          PackFile,
          $$PackFilesTableFilterComposer,
          $$PackFilesTableOrderingComposer,
          $$PackFilesTableAnnotationComposer,
          $$PackFilesTableCreateCompanionBuilder,
          $$PackFilesTableUpdateCompanionBuilder,
          (PackFile, BaseReferences<_$LibraryIndex, $PackFilesTable, PackFile>),
          PackFile,
          PrefetchHooks Function()
        > {
  $$PackFilesTableTableManager(_$LibraryIndex db, $PackFilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PackFilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PackFilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PackFilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> packId = const Value.absent(),
                Value<String> relPath = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PackFilesCompanion(
                packId: packId,
                relPath: relPath,
                size: size,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String packId,
                required String relPath,
                required int size,
                Value<int> rowid = const Value.absent(),
              }) => PackFilesCompanion.insert(
                packId: packId,
                relPath: relPath,
                size: size,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PackFilesTable, PackFile>(table),
                  BaseReferences<_$LibraryIndex, $PackFilesTable, PackFile>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PackFilesTableProcessedTableManager =
    ProcessedTableManager<
      _$LibraryIndex,
      $PackFilesTable,
      PackFile,
      $$PackFilesTableFilterComposer,
      $$PackFilesTableOrderingComposer,
      $$PackFilesTableAnnotationComposer,
      $$PackFilesTableCreateCompanionBuilder,
      $$PackFilesTableUpdateCompanionBuilder,
      (PackFile, BaseReferences<_$LibraryIndex, $PackFilesTable, PackFile>),
      PackFile,
      PrefetchHooks Function()
    >;
typedef $$ScanStatesTableCreateCompanionBuilder = ScanStatesCompanion Function({
  required String root,
  required String fingerprint,
  required DateTime scannedAt,
  Value<int> rowid,
});
typedef $$ScanStatesTableUpdateCompanionBuilder = ScanStatesCompanion Function({
  Value<String> root,
  Value<String> fingerprint,
  Value<DateTime> scannedAt,
  Value<int> rowid,
});

class $$ScanStatesTableFilterComposer
    extends Composer<_$LibraryIndex, $ScanStatesTable> {
  $$ScanStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get root => $composableBuilder(
    column: $table.root,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get scannedAt => $composableBuilder(
    column: $table.scannedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ScanStatesTableOrderingComposer
    extends Composer<_$LibraryIndex, $ScanStatesTable> {
  $$ScanStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get root => $composableBuilder(
    column: $table.root,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get scannedAt => $composableBuilder(
    column: $table.scannedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ScanStatesTableAnnotationComposer
    extends Composer<_$LibraryIndex, $ScanStatesTable> {
  $$ScanStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get root =>
      $composableBuilder(column: $table.root, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get scannedAt =>
      $composableBuilder(column: $table.scannedAt, builder: (column) => column);
}

class $$ScanStatesTableTableManager
    extends
        RootTableManager<
          _$LibraryIndex,
          $ScanStatesTable,
          ScanState,
          $$ScanStatesTableFilterComposer,
          $$ScanStatesTableOrderingComposer,
          $$ScanStatesTableAnnotationComposer,
          $$ScanStatesTableCreateCompanionBuilder,
          $$ScanStatesTableUpdateCompanionBuilder,
          (
            ScanState,
            BaseReferences<_$LibraryIndex, $ScanStatesTable, ScanState>,
          ),
          ScanState,
          PrefetchHooks Function()
        > {
  $$ScanStatesTableTableManager(_$LibraryIndex db, $ScanStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScanStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScanStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScanStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> root = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
                Value<DateTime> scannedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScanStatesCompanion(
                root: root,
                fingerprint: fingerprint,
                scannedAt: scannedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String root,
                required String fingerprint,
                required DateTime scannedAt,
                Value<int> rowid = const Value.absent(),
              }) => ScanStatesCompanion.insert(
                root: root,
                fingerprint: fingerprint,
                scannedAt: scannedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ScanStatesTable, ScanState>(table),
                  BaseReferences<_$LibraryIndex, $ScanStatesTable, ScanState>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ScanStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$LibraryIndex,
      $ScanStatesTable,
      ScanState,
      $$ScanStatesTableFilterComposer,
      $$ScanStatesTableOrderingComposer,
      $$ScanStatesTableAnnotationComposer,
      $$ScanStatesTableCreateCompanionBuilder,
      $$ScanStatesTableUpdateCompanionBuilder,
      (ScanState, BaseReferences<_$LibraryIndex, $ScanStatesTable, ScanState>),
      ScanState,
      PrefetchHooks Function()
    >;

class $LibraryIndexManager {
  final _$LibraryIndex _db;
  $LibraryIndexManager(this._db);
  $$PacksTableTableManager get packs =>
      $$PacksTableTableManager(_db, _db.packs);
  $$PackFilesTableTableManager get packFiles =>
      $$PackFilesTableTableManager(_db, _db.packFiles);
  $$ScanStatesTableTableManager get scanStates =>
      $$ScanStatesTableTableManager(_db, _db.scanStates);
}
