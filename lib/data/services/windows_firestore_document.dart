class WindowsFirestoreRestDocument {
  const WindowsFirestoreRestDocument({
    required this.id,
    required this.path,
    required this.data,
  });

  final String id;
  final String path;
  final Map<String, dynamic> data;
}
