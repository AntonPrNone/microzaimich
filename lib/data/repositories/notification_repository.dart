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
    await _firestoreService.notifications.doc(notificationId).update({
      'readAt': AppClock.nowForStorage(),
    });
  }

  Future<void> markAllAsRead(String userId) async {
    final snapshot = await _firestoreService.notifications
        .where('userId', isEqualTo: userId)
        .where('readAt', isNull: true)
        .get();
    for (final doc in snapshot.docs) {
      await doc.reference.update({'readAt': AppClock.nowForStorage()});
    }
  }

  Future<void> deleteForUser(String userId) async {
    final snapshot = await _firestoreService.notifications
        .where('userId', isEqualTo: userId)
        .get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }
}
