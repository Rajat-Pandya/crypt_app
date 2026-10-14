// test/mocks/firebase_mocks.dart
// Firebase mocking utilities for unit tests
// These provide simple interfaces for testing without full Firebase initialization

/// Mock User for testing - provides test user data without Firebase
class MockUser {
  final String uid;
  final String? email;
  final bool emailVerified;
  
  const MockUser({
    this.uid = 'test_uid_123',
    this.email = 'test@example.com',
    this.emailVerified = true,
  });
  
  @override
  String toString() => 'MockUser(uid: $uid, email: $email)';
}

/// Mock Collection Reference for Firestore testing
class MockCollectionReference {
  final String id;
  
  MockCollectionReference({this.id = 'test_collection'});
  
  MockDocumentReference doc([String? path]) {
    return MockDocumentReference(id: path ?? 'test_doc_id');
  }
  
  Future<MockDocumentReference> add(Map<String, dynamic> data) async {
    return MockDocumentReference(id: 'new_doc_id');
  }
}

/// Mock Document Reference for Firestore testing
class MockDocumentReference {
  final String id;
  
  MockDocumentReference({this.id = 'test_doc_id'});
  
  Future<void> set(Map<String, dynamic> data) async {}
  Future<void> update(Map<String, dynamic> data) async {}
  Future<void> delete() async {}
  Future<MockDocumentSnapshot> get() async {
    return MockDocumentSnapshot();
  }
}

/// Mock Document Snapshot for Firestore testing
class MockDocumentSnapshot {
  final bool exists;
  final String id;
  final Map<String, dynamic>? _data;
  
  MockDocumentSnapshot({
    this.exists = true,
    this.id = 'test_doc_id',
    Map<String, dynamic>? data,
  }) : _data = data ?? {'test': 'data'};
  
  Map<String, dynamic>? data() => _data;
}

/// Mock Query Snapshot for Firestore testing
class MockQuerySnapshot {
  final List<MockQueryDocumentSnapshot> docs;
  
  MockQuerySnapshot({this.docs = const []});
}

/// Mock Query Document Snapshot for Firestore testing
class MockQueryDocumentSnapshot {
  final String id;
  final Map<String, dynamic> _data;
  
  MockQueryDocumentSnapshot({
    this.id = 'test_doc_id',
    Map<String, dynamic>? data,
  }) : _data = data ?? {'test': 'data'};
  
  Map<String, dynamic> data() => _data;
}

/// Firebase test utilities - simple helpers for testing
class FirebaseTestUtils {
  static MockUser get currentUser => const MockUser();
  static String get currentUserId => currentUser.uid;
  
  /// Setup test environment
  static void setUp() {
    // Initialize test mocks
  }
  
  /// Cleanup after tests
  static void tearDown() {
    // Cleanup mocks
  }
  
  /// Create a mock authenticated user
  static MockUser createMockUser({
    String uid = 'test_uid_123',
    String email = 'test@example.com',
    bool emailVerified = true,
  }) {
    return MockUser(
      uid: uid,
      email: email,
      emailVerified: emailVerified,
    );
  }
}
