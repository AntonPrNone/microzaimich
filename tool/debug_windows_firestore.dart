import 'dart:io';

import 'package:firedart/firedart.dart' as fd;
import 'package:microzaimich/firebase_options.dart';

Future<void> main() async {
  fd.Firestore.initialize(DefaultFirebaseOptions.windows.projectId);
  final firestore = fd.Firestore.instance;

  stdout.writeln('before users get');
  final users = await firestore.collection('users').get(pageSize: 5);
  stdout.writeln('users ok count=${users.length} next=${users.nextPageToken}');

  stdout.writeln('before admin query');
  final admins = await firestore
      .collection('users')
      .where('role', isEqualTo: 'admin')
      .limit(1)
      .get();
  stdout.writeln('admins ok count=${admins.length}');

  stdout.writeln('before payment settings doc');
  final payment = await firestore.document('app_settings/payment').get();
  stdout.writeln('payment ok id=${payment.id}');
}
