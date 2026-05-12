import '../../core/utils/platform_utils.dart';
import '../models/app_notification.dart';
import '../services/app_clock.dart';
import '../models/user_role.dart';
import '../services/firestore_service.dart';

class NotificationRepository {
  NotificationRepository({
    required FirestoreService firestoreService,
  }) : _firestoreService = firestoreService;

  final FirestoreService _firestoreService;

  Stream<List<AppNotification>> watchForUser(String userId) {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchCollectionWhereEqual(
            'notifications',
            fieldPath: 'userId',
            isEqualTo: userId,
          )
          .map(
            (docs) {
              final notificationsById = <String, AppNotification>{};
              for (final doc in docs) {
                notificationsById[doc.id] = AppNotification.fromMap(doc.id, doc.data);
              }
              final notifications = notificationsById.values.toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
              return notifications;
            },
          );
    }

    return _firestoreService.notifications
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(AppNotification.fromDoc)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
        );
  }

  Future<void> notifyUser({
    required String userId,
    required String title,
    required String body,
    required AppNotificationType type,
  }) async {
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.createDocument('notifications', {
        'userId': userId,
        'title': title,
        'body': body,
        'type': type.name,
        'createdAt': AppClock.nowForStorage(),
        'readAt': null,
      });
      return;
    }

    final ref = _firestoreService.notifications.doc();
    final notification = AppNotification(
      id: ref.id,
      userId: userId,
      title: title,
      body: body,
      type: type,
      createdAt: AppClock.nowForStorage(),
    );
    await ref.set(notification.toMap());
  }

  Future<void> notifyAdmins({
    required String title,
    required String body,
    required AppNotificationType type,
  }) async {
    if (AppPlatform.isWindows) {
      final admins = await _firestoreService.windowsStream!.queryDocuments(
        'users',
        whereField: 'role',
        isEqualTo: UserRole.admin.value,
      );
      for (final admin in admins.where(
        (doc) => doc.data['role'] == UserRole.admin.value,
      )) {
        await notifyUser(
          userId: admin.id,
          title: title,
          body: body,
          type: type,
        );
      }
      return;
    }

    final adminsSnapshot = await _firestoreService.users
        .where('role', isEqualTo: UserRole.admin.value)
        .get();
    for (final admin in adminsSnapshot.docs) {
      await notifyUser(
        userId: admin.id,
        title: title,
        body: body,
        type: type,
      );
    }
  }

  Future<void> markAsRead(String notificationId) async {
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument(
        'notifications/$notificationId',
        {
          'readAt': AppClock.nowForStorage(),
        },
      );
      return;
    }
    await _firestoreService.notifications.doc(notificationId).update({
      'readAt': AppClock.nowForStorage(),
    });
  }

  Future<void> markAllAsRead(String userId) async {
    if (AppPlatform.isWindows) {
      final docs = await _firestoreService.windowsStream!.queryDocuments(
        'notifications',
        whereField: 'userId',
        isEqualTo: userId,
      );
      for (final doc in docs.where(
        (doc) => doc.data['userId'] == userId && doc.data['readAt'] == null,
      )) {
        await _firestoreService.windowsStream!.updateDocument(
          'notifications/${doc.id}',
          {'readAt': AppClock.nowForStorage()},
        );
      }
      return;
    }

    final snapshot = await _firestoreService.notifications
        .where('userId', isEqualTo: userId)
        .where('readAt', isNull: true)
        .get();
    for (final doc in snapshot.docs) {
      await doc.reference.update({'readAt': AppClock.nowForStorage()});
    }
  }

  Future<void> deleteForUser(String userId) async {
    if (AppPlatform.isWindows) {
      final docs = await _firestoreService.windowsStream!.queryDocuments(
        'notifications',
        whereField: 'userId',
        isEqualTo: userId,
      );
      for (final doc in docs) {
        await _firestoreService.windowsStream!.deleteDocument(
          'notifications/${doc.id}',
        );
      }
      return;
    }

    final snapshot = await _firestoreService.notifications
        .where('userId', isEqualTo: userId)
        .get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }
}
