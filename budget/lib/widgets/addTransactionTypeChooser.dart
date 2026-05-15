/// Bottom-sheet chooser shown by the main FAB short-tap. The user picks
/// between the existing manual-entry flow and the new import-from-file
/// flow. The long-press FAB still shows `AddMoreThingsPopup`.
library;

import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/autoTransactionsPageImport.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';

class AddTransactionTypeChooser extends StatelessWidget {
  const AddTransactionTypeChooser({super.key});

  @override
  Widget build(BuildContext context) {
    final outlined = appStateSettings["outlinedIcons"] == true;
    return Column(
      children: [
        const SizedBox(height: 5),
        AddThing(
          iconData: outlined
              ? Icons.edit_outlined
              : Icons.edit_rounded,
          title: "Manual entry",
          openPage: AddTransactionPage(
            routesToPopAfterDelete: RoutesToPopAfterDelete.None,
          ),
        ),
        AddThing(
          iconData: outlined
              ? Icons.upload_file_outlined
              : Icons.upload_file_rounded,
          title: "Import from file",
          openPage: const AutoTransactionsPageImport(),
        ),
      ],
    );
  }
}
