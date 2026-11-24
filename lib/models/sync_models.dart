import 'category_model.dart';
import 'scope_models.dart';
import 'transaction_model.dart';

/// One cloud collection of transactions as seen by the signed-in user:
/// their personal collection (`users/{uid}/transactions`) or a household's
/// shared one (`households/{householdId}/transactions`).
class CloudPartition {
  const CloudPartition(this.uid, this.scope);

  const CloudPartition.personal(this.uid) : scope = const DataScope.personal();

  CloudPartition.household(this.uid, String householdId)
    : scope = DataScope.household(householdId);

  /// The signed-in user doing the reading and writing.
  final String uid;
  final DataScope scope;

  bool get isPersonal => scope.isPersonal;
  String? get householdId => scope.householdId;

  /// Identifies the collection (the UID for personal data).
  String get key => scope.isPersonal ? uid : scope.key;

  @override
  bool operator ==(Object other) =>
      other is CloudPartition && other.uid == uid && other.scope == scope;

  @override
  int get hashCode => Object.hash(uid, scope);

  @override
  String toString() => 'CloudPartition($key)';
}

/// Category fields stored with every cloud transaction, so another device
/// (or this one after a reinstall) can recreate a custom category that the
/// transaction refers to.
class CategorySnapshot {
  const CategorySnapshot({
    required this.id,
    required this.name,
    required this.type,
    required this.iconKey,
    required this.colorValue,
  });

  factory CategorySnapshot.of(CategoryModel category) => CategorySnapshot(
    id: category.id,
    name: category.name,
    type: category.type,
    iconKey: category.iconKey,
    colorValue: category.colorValue,
  );

  final String id;
  final String name;
  final TransactionType type;
  final String iconKey;
  final int colorValue;

  /// A custom (deletable) category built from this snapshot.
  CategoryModel toCategory({int sortOrder = 0}) => CategoryModel(
    id: id,
    name: name,
    type: type,
    iconKey: iconKey,
    colorValue: colorValue,
    sortOrder: sortOrder,
  );

  Map<String, Object?> toCloudMap() => {
    'id': id,
    'name': name,
    'type': type.name,
    'iconKey': iconKey,
    'colorValue': colorValue,
  };

  static CategorySnapshot? fromCloudMap(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final type = value['type'];
    final iconKey = value['iconKey'];
    final color = value['colorValue'];
    if (id is! String || name is! String || type is! String) return null;
    if (iconKey is! String || color is! int) return null;
    return CategorySnapshot(
      id: id,
      name: name,
      type: TransactionType.fromName(type),
      iconKey: iconKey,
      colorValue: color,
    );
  }
}

/// Position in the cloud change feed: the server time a document was last
/// written (microseconds) and its ID, which breaks ties between documents
/// written by the same batch.
class SyncCursor implements Comparable<SyncCursor> {
  const SyncCursor(this.serverMicros, this.docId);

  final int serverMicros;
  final String docId;

  @override
  int compareTo(SyncCursor other) {
    final byTime = serverMicros.compareTo(other.serverMicros);
    return byTime != 0 ? byTime : docId.compareTo(other.docId);
  }

  bool isAfter(SyncCursor other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is SyncCursor &&
      other.serverMicros == serverMicros &&
      other.docId == docId;

  @override
  int get hashCode => Object.hash(serverMicros, docId);

  @override
  String toString() => 'SyncCursor($serverMicros, $docId)';
}

/// A transaction document as stored in Cloud Firestore.
///
/// Deleting a transaction in the app never removes its cloud document: the
/// document is kept with [deleted] set, which lets other devices apply the
/// deletion and resolve conflicts by [updatedAt].
class CloudTransaction {
  const CloudTransaction({
    required this.transaction,
    this.deleted = false,
    this.category,
    this.position,
    this.isLegacy = false,
  });

  /// Document schema version, for future format changes. v2 added the
  /// scope, owner / household and author fields.
  static const int schemaVersion = 2;

  /// The record. For deleted documents `updatedAt` is the deletion time.
  final TransactionModel transaction;
  final bool deleted;
  final CategorySnapshot? category;

  /// Where this document sits in the change feed (set when read).
  final SyncCursor? position;

  /// True for a personal document written before v2 (no `scope` field);
  /// sync adds the missing fields.
  final bool isLegacy;

  String get id => transaction.id;
  DateTime get updatedAt => transaction.updatedAt;
  int get updatedAtMs => transaction.updatedAt.millisecondsSinceEpoch;

  /// True when this document holds exactly [local] (all fields and the same
  /// `updatedAt`) and is not deleted.
  bool matches(TransactionModel local) =>
      !deleted && contentEquals(transaction, local);

  CloudTransaction copyWith({bool? deleted, SyncCursor? position}) =>
      CloudTransaction(
        transaction: transaction,
        deleted: deleted ?? this.deleted,
        category: category,
        position: position ?? this.position,
        isLegacy: isLegacy,
      );

  /// Fields identifying who owns the document, written by [partition]'s
  /// user. The collection decides the scope, never the local row.
  static Map<String, Object?> ownershipFields(
    CloudPartition partition,
    TransactionModel transaction,
  ) => partition.isPersonal
      ? {
          'scope': TransactionScope.personal.name,
          'ownerUid': partition.uid,
          'createdBy': partition.uid,
        }
      : {
          'scope': TransactionScope.shared.name,
          'householdId': partition.householdId,
          'createdBy': transaction.createdBy ?? partition.uid,
          'createdByName': transaction.createdByName,
          // Whoever uploads a version is its author.
          'updatedBy': partition.uid,
        };

  /// Field map written to Firestore (server timestamp added by the store).
  Map<String, Object?> toCloudMap(CloudPartition partition) => {
    'schemaVersion': schemaVersion,
    ...ownershipFields(partition, transaction),
    'id': transaction.id,
    'type': transaction.type.name,
    'amountMinor': transaction.amountMinor,
    'categoryId': transaction.categoryId,
    'date': transaction.date.millisecondsSinceEpoch,
    'note': transaction.note,
    'paymentMethod': transaction.paymentMethod.name,
    'createdAt': transaction.createdAt.millisecondsSinceEpoch,
    'updatedAt': transaction.updatedAt.millisecondsSinceEpoch,
    'deleted': deleted,
    'deletedAt': deleted ? transaction.updatedAt.millisecondsSinceEpoch : null,
    if (category != null) 'category': category!.toCloudMap(),
  };

  /// Parses a Firestore document. Throws [FormatException] if required
  /// fields are missing or invalid.
  ///
  /// The scope and household come from [partition] (the collection the
  /// document was read from), not from the document.
  factory CloudTransaction.fromCloudMap(
    String docId,
    Map<String, Object?> map, {
    SyncCursor? position,
    CloudPartition? partition,
  }) {
    T field<T>(String key) {
      final value = map[key];
      if (value is T) return value;
      throw FormatException('Cloud transaction $docId: bad "$key"');
    }

    final amount = field<int>('amountMinor');
    if (amount <= 0) {
      throw FormatException('Cloud transaction $docId: bad "amountMinor"');
    }
    return CloudTransaction(
      transaction: TransactionModel(
        id: docId,
        type: TransactionType.fromName(field<String>('type')),
        amountMinor: amount,
        categoryId: field<String>('categoryId'),
        date: DateTime.fromMillisecondsSinceEpoch(field<int>('date')),
        note: (map['note'] as String?) ?? '',
        paymentMethod: PaymentMethod.fromName(
          (map['paymentMethod'] as String?) ?? '',
        ),
        createdAt: DateTime.fromMillisecondsSinceEpoch(field<int>('createdAt')),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(field<int>('updatedAt')),
        scope: partition?.scope.transactionScope ?? TransactionScope.personal,
        householdId: partition?.householdId,
        createdBy: map['createdBy'] as String?,
        createdByName: map['createdByName'] as String?,
        updatedBy: map['updatedBy'] as String?,
      ),
      deleted: map['deleted'] == true,
      category: CategorySnapshot.fromCloudMap(map['category']),
      position: position,
      isLegacy: map['scope'] == null,
    );
  }
}

/// Field-by-field equality including `createdAt` and `updatedAt`
/// (compared in milliseconds, the precision stored on both sides).
bool contentEquals(TransactionModel a, TransactionModel b) =>
    a.id == b.id &&
    a.type == b.type &&
    a.amountMinor == b.amountMinor &&
    a.categoryId == b.categoryId &&
    a.date.millisecondsSinceEpoch == b.date.millisecondsSinceEpoch &&
    a.note == b.note &&
    a.paymentMethod == b.paymentMethod &&
    a.createdAt.millisecondsSinceEpoch == b.createdAt.millisecondsSinceEpoch &&
    a.updatedAt.millisecondsSinceEpoch == b.updatedAt.millisecondsSinceEpoch;

/// A local change waiting to be uploaded.
sealed class LocalChange {
  const LocalChange();

  String get id;
}

/// A transaction created or edited on this device.
class LocalUpsert extends LocalChange {
  const LocalUpsert(this.transaction, {this.category});

  final TransactionModel transaction;
  final CategorySnapshot? category;

  @override
  String get id => transaction.id;
}

/// A transaction deleted on this device.
class LocalDeletion extends LocalChange {
  const LocalDeletion(this.id, this.deletedAt);

  @override
  final String id;
  final DateTime deletedAt;
}

/// A budget or category document in a personal or household collection.
///
/// These collections are small, so they are read in full on every sync and
/// merged by `updatedAt` (last writer wins). Deletions are kept as
/// documents with `deleted: true`, never removed.
class CloudRecord {
  const CloudRecord({
    required this.id,
    required this.data,
    required this.updatedAtMs,
    this.deleted = false,
  });

  /// Parses a document; returns null when it has no valid `updatedAt`.
  static CloudRecord? fromCloudMap(String id, Map<String, Object?> map) {
    final updated = map['updatedAt'];
    if (updated is! int) return null;
    return CloudRecord(
      id: id,
      data: map,
      updatedAtMs: updated,
      deleted: map['deleted'] == true,
    );
  }

  final String id;
  final Map<String, Object?> data;
  final int updatedAtMs;
  final bool deleted;

  /// A deletion marker for [id].
  factory CloudRecord.deletion(String id, int deletedAtMs) => CloudRecord(
    id: id,
    data: {
      'id': id,
      'deleted': true,
      'updatedAt': deletedAtMs,
      'deletedAt': deletedAtMs,
    },
    updatedAtMs: deletedAtMs,
    deleted: true,
  );
}

/// Which small collection a [CloudRecord] belongs to.
enum CloudRecordKind {
  /// `personalBudgets` / household `budgets`.
  budgets,

  /// `personalCategories` / household `categories`.
  categories,
}

/// What applying one cloud document did to the local database.
enum RemoteApplyOutcome {
  /// Nothing to do (already up to date, or the local copy is newer).
  unchanged,
  inserted,
  updated,
  deleted,

  /// Older than the local retention window and not stored on this device;
  /// it stays in the cloud and is shown from there on request.
  skippedArchived,
}

/// Summary of one sync cycle.
class SyncReport {
  SyncReport();

  int uploaded = 0;
  int deletionsUploaded = 0;
  int downloaded = 0;
  int deletedFromCloud = 0;

  /// Local changes discarded because the cloud had a newer version.
  int conflictsWonByCloud = 0;
  int failed = 0;

  /// Transactions removed from this device by the retention clean-up (they
  /// remain in the cloud).
  int archivedLocally = 0;

  /// Budget and category documents applied locally from the cloud.
  int budgetsDownloaded = 0;
  int categoriesDownloaded = 0;

  /// Budget and category changes uploaded.
  int settingsUploaded = 0;

  /// Households whose cloud data could not be read because this user is no
  /// longer an active member.
  final Set<String> householdsDenied = {};

  /// True when a personal data reset made on another device was applied
  /// here (pre-reset records removed from this device).
  bool resetApplied = false;

  /// True when downloads were skipped because the user reset this device
  /// and has not restored their cloud data yet.
  bool restorePending = false;

  /// True when this cycle was a successful Restore My Cloud Data.
  bool restored = false;

  /// True when local transactions changed, so the UI should reload.
  bool get localDataChanged =>
      resetApplied ||
      restored ||
      downloaded > 0 ||
      deletedFromCloud > 0 ||
      conflictsWonByCloud > 0 ||
      archivedLocally > 0 ||
      categoriesDownloaded > 0 ||
      budgetsDownloaded > 0;

  void addAll(SyncReport other) {
    uploaded += other.uploaded;
    deletionsUploaded += other.deletionsUploaded;
    downloaded += other.downloaded;
    deletedFromCloud += other.deletedFromCloud;
    conflictsWonByCloud += other.conflictsWonByCloud;
    failed += other.failed;
    archivedLocally += other.archivedLocally;
    budgetsDownloaded += other.budgetsDownloaded;
    categoriesDownloaded += other.categoriesDownloaded;
    settingsUploaded += other.settingsUploaded;
    householdsDenied.addAll(other.householdsDenied);
    resetApplied |= other.resetApplied;
    restorePending |= other.restorePending;
    restored |= other.restored;
  }

  @override
  String toString() =>
      'SyncReport(uploaded: $uploaded, deletionsUploaded: $deletionsUploaded, '
      'downloaded: $downloaded, deletedFromCloud: $deletedFromCloud, '
      'conflictsWonByCloud: $conflictsWonByCloud, failed: $failed, '
      'archivedLocally: $archivedLocally, budgetsDownloaded: '
      '$budgetsDownloaded, categoriesDownloaded: $categoriesDownloaded)';
}
