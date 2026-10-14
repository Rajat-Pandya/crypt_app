import 'package:cloud_firestore/cloud_firestore.dart';

/// Stub SnapshotMetadata for error fallback
/// 
/// Returns default values to satisfy type constraints when creating
/// stub QuerySnapshot instances for error handling.
class FakeSnapshotMetadata implements SnapshotMetadata {
  @override
  bool get fromCache => false;

  @override
  bool get isFromCache => false;

  @override
  bool get hasPendingWrites => false;
}

/// Stub QuerySnapshot for error fallback
///
/// Returns empty list to show "No messages" instead of infinite loading.
/// Used when Firestore queries fail to provide a graceful degradation.
class StubQuerySnapshot<T extends Object?> implements QuerySnapshot<T> {
  @override
  List<QueryDocumentSnapshot<T>> get docs => [];

  @override
  SnapshotMetadata get metadata => FakeSnapshotMetadata();

  @override
  int get size => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
