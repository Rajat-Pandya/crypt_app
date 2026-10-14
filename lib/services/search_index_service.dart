import 'package:hive/hive.dart';

/// Local search index service for fast offline message search.
/// 
/// Maintains a Hive box mapping messageId → normalized tokens and metadata.
/// Index is per-device only and never sent to Firestore.
/// Local search index service for fast offline message search.
/// 
/// Maintains a Hive box mapping messageId → normalized tokens and metadata.
/// Index is per-device only and never sent to Firestore.
/// 
/// Note: This is a singleton. Use [instance] to access it.
class SearchIndexService {
  static final SearchIndexService _instance = SearchIndexService._internal();
  
  /// Singleton instance accessor.
  /// 
  /// Use this instead of calling the constructor directly:
  ///   // Good:
  ///   SearchIndexService.instance.search(query);
  ///   
  ///   // Still works but less explicit:
  ///   SearchIndexService().search(query);
  static SearchIndexService get instance => _instance;
  
  @Deprecated('Use SearchIndexService.instance instead')
  factory SearchIndexService() => _instance;
  
  SearchIndexService._internal();

  Box<dynamic>? _indexBox;
  bool _initialized = false;

  // Stop words to filter out during tokenization
  static const Set<String> _stopWords = {
    'a', 'an', 'the', 'is', 'are', 'was', 'were',
    'be', 'been', 'being', 'have', 'has', 'had',
    'do', 'does', 'did', 'will', 'would', 'could',
    'should', 'may', 'might', 'must', 'shall',
    'can', 'need', 'dare', 'ought', 'used',
    'to', 'of', 'in', 'for', 'on', 'with',
    'at', 'by', 'from', 'as', 'into', 'through',
    'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'again', 'further', 'then',
    'once', 'here', 'there', 'when', 'where',
    'why', 'how', 'all', 'each', 'few', 'more',
    'most', 'other', 'some', 'such', 'no', 'nor',
    'not', 'only', 'own', 'same', 'so', 'than',
    'too', 'very', 'just', 'and', 'but', 'if',
    'or', 'because', 'until', 'while', 'what',
    'which', 'who', 'whom', 'this', 'that',
    'these', 'those', 'am', 'it', 'its',
  };

  /// Initialize the search index service
  Future<void> initialize() async {
    if (_initialized) return;
    
    _indexBox = await Hive.openBox('search_index');
    _initialized = true;
  }

  /// Check if service is initialized
  bool get isInitialized => _initialized;

  /// Tokenize plaintext into searchable tokens
  List<String> tokenize(String plaintext) {
    // Normalize: lowercase and split on whitespace and punctuation
    final normalized = plaintext.toLowerCase();
    final tokens = normalized.split(RegExp(r'[\s\p{P}]+', unicode: true));
    
    // Filter: min 3 chars, not stop word
    return tokens.where((token) {
      if (token.length < 3) return false;
      if (_stopWords.contains(token)) return false;
      return true;
    }).toList();
  }

  /// Index a message after successful decryption
  /// 
  /// Call this from MessageRepository or EncryptionBloc when decryption succeeds
  Future<void> indexMessage({
    required String messageId,
    required String plaintext,
    required String senderId,
    required DateTime timestamp,
    required String roomId,
    bool hasMedia = false,
  }) async {
    if (!_initialized) await initialize();
    
    // Skip empty or error messages
    if (plaintext.isEmpty || plaintext.startsWith('🔒')) return;
    
    final tokens = tokenize(plaintext);
    if (tokens.isEmpty) return;
    
    final indexEntry = {
      'tokens': tokens,
      'senderId': senderId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'hasMedia': hasMedia,
      'roomId': roomId,
      'indexedAt': DateTime.now().millisecondsSinceEpoch,
    };
    
    await _indexBox?.put(messageId, indexEntry);
  }

  /// Search for messages matching the query
  /// 
  /// Returns messageIds ranked by token hit count (most recent first)
  List<String> search(
    String query, {
    String? roomId,
    SearchFilters? filters,
  }) {
    if (!_initialized || query.isEmpty) return [];
    
    final searchTokens = tokenize(query);
    if (searchTokens.isEmpty) return [];
    
    final results = <String, int>{}; // messageId → hit count
    
    // Scan all index entries
    final entries = _indexBox?.toMap().entries;
    if (entries == null) return [];
    
    for (final entry in entries) {
      final messageId = entry.key as String?;
      if (messageId == null) continue;
      final data = entry.value as Map<dynamic, dynamic>?;
      if (data == null) continue;
      
      // Apply room filter
      if (roomId != null && data['roomId'] != roomId) continue;
      
      // Apply date filters
      if (filters != null) {
        final timestamp = DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int);
        
        if (filters.fromDate != null && timestamp.isBefore(filters.fromDate!)) {
          continue;
        }
        if (filters.toDate != null && timestamp.isAfter(filters.toDate!)) {
          continue;
        }
        
        // Apply media filter
        if (filters.mediaOnly == true && data['hasMedia'] != true) {
          continue;
        }
        
        // Apply sender filter
        if (filters.senderIdFilter != null && 
            data['senderId'] != filters.senderIdFilter) {
          continue;
        }
      }
      
      // Token matching
      final tokens = (data['tokens'] as List<dynamic>?)?.cast<String>() ?? [];
      int hitCount = 0;
      
      for (final searchToken in searchTokens) {
        for (final token in tokens) {
          if (token.contains(searchToken) || searchToken.contains(token)) {
            hitCount++;
          }
        }
      }
      
      if (hitCount > 0) {
        results[messageId] = hitCount;
      }
    }
    
    // Sort by hit count (descending), then by timestamp (most recent first)
    final sortedResults = results.entries.toList()
      ..sort((a, b) {
        final hitCompare = b.value.compareTo(a.value);
        if (hitCompare != 0) return hitCompare;
        
        // Tie-break by timestamp (most recent first)
        final aData = _indexBox?.get(a.key) as Map<dynamic, dynamic>?;
        final bData = _indexBox?.get(b.key) as Map<dynamic, dynamic>?;
        final aTime = aData?['timestamp'] as int? ?? 0;
        final bTime = bData?['timestamp'] as int? ?? 0;
        return bTime.compareTo(aTime);
      });
    
    return sortedResults.map((e) => e.key).toList();
  }

  /// Clear index for a specific room
  Future<void> clearIndex(String roomId) async {
    if (!_initialized) return;
    
    final keysToDelete = <String>[];
    
    final entries = _indexBox?.toMap().entries;
    if (entries == null) return;
    
    for (final entry in entries) {
      final data = entry.value as Map<dynamic, dynamic>?;
      final key = entry.key as String?;
      if (data != null && key != null && data['roomId'] == roomId) {
        keysToDelete.add(key);
      }
    }
    
    for (final key in keysToDelete) {
      await _indexBox?.delete(key);
    }
  }

  /// Clear entire index
  Future<void> clearAll() async {
    if (!_initialized) return;
    await _indexBox?.clear();
  }

  /// Check if a message is indexed
  bool isIndexed(String messageId) {
    if (!_initialized) return false;
    return _indexBox?.containsKey(messageId) ?? false;
  }

  /// Remove a specific message from index
  Future<void> removeFromIndex(String messageId) async {
    if (!_initialized) return;
    await _indexBox?.delete(messageId);
  }

  /// Get index stats for debugging
  Map<String, dynamic> getStats() {
    if (!_initialized) return {};
    
    final entryCount = _indexBox?.length ?? 0;
    final roomIds = <String>{};
    
    final entries = _indexBox?.toMap().entries;
    if (entries != null) {
      for (final entry in entries) {
        final data = entry.value as Map<dynamic, dynamic>?;
        if (data != null) {
          roomIds.add(data['roomId'] as String? ?? 'unknown');
        }
      }
    }
    
    return {
      'totalEntries': entryCount,
      'rooms': roomIds.length,
      'roomIds': roomIds.toList(),
    };
  }

  /// Dispose service
  Future<void> dispose() async {
    if (_initialized) {
      await _indexBox?.close();
      _initialized = false;
    }
  }
}

/// Search filters for advanced search
class SearchFilters {
  final DateTime? fromDate;
  final DateTime? toDate;
  final bool mediaOnly;
  final String? senderIdFilter;

  const SearchFilters({
    this.fromDate,
    this.toDate,
    this.mediaOnly = false,
    this.senderIdFilter,
  });

  SearchFilters copyWith({
    DateTime? fromDate,
    DateTime? toDate,
    bool? mediaOnly,
    String? senderIdFilter,
  }) {
    return SearchFilters(
      fromDate: fromDate ?? this.fromDate,
      toDate: toDate ?? this.toDate,
      mediaOnly: mediaOnly ?? this.mediaOnly,
      senderIdFilter: senderIdFilter ?? this.senderIdFilter,
    );
  }

  bool get isActive {
    return fromDate != null || 
           toDate != null || 
           mediaOnly == true || 
           senderIdFilter != null;
  }

  Map<String, dynamic> toJson() {
    return {
      'fromDate': fromDate?.millisecondsSinceEpoch,
      'toDate': toDate?.millisecondsSinceEpoch,
      'mediaOnly': mediaOnly,
      'senderIdFilter': senderIdFilter,
    };
  }

  factory SearchFilters.fromJson(Map<String, dynamic> json) {
    return SearchFilters(
      fromDate: json['fromDate'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(json['fromDate'] as int)
          : null,
      toDate: json['toDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['toDate'] as int)
          : null,
      mediaOnly: json['mediaOnly'] as bool? ?? false,
      senderIdFilter: json['senderIdFilter'] as String?,
    );
  }
}
