import 'package:firedart/firedart.dart' as fd;

import '../lib/firebase_options.dart';

Future<void> main() async {
  fd.Firestore.initialize(DefaultFirebaseOptions.windows.projectId);
  final firestore = fd.Firestore.instance;

  print('before users get');
  final users = await firestore.collection('users').get(pageSize: 5);
  print('users ok count=${users.length} next=${users.nextPageToken}');

  print('before admin query');
  final admins = await firestore
      .collection('users')
      .where('role', isEqualTo: 'admin')
      .limit(1)
      .get();
  print('admins ok count=${admins.length}');

  print('before payment settings doc');
  final payment = await firestore.document('app_settings/payment').get();
  print('payment ok id=${payment.id}');
}
