import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../features/feature_widgets.dart';
import '../plugins/plugin_widgets.dart';
import '../theme/app_icons.dart';

Future<SkillInfo?> showBotSkillSheet(BuildContext context, Future<List<SkillInfo>> Function() load) =>
    showAppSheet<SkillInfo>(context, builder: (_) => _BotSkillSheet(load: load));

class _BotSkillSheet extends StatefulWidget {
  const _BotSkillSheet({required this.load});

  final Future<List<SkillInfo>> Function() load;

  @override
  State<_BotSkillSheet> createState() => _BotSkillSheetState();
}

class _BotSkillSheetState extends State<_BotSkillSheet> {
  late Future<List<SkillInfo>> _skills = widget.load();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(l10n.featuresSkills),
          Flexible(
            child: FutureBuilder<List<SkillInfo>>(
              future: _skills,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) return const FeatureLoading();
                if (snapshot.hasError) {
                  return SingleChildScrollView(
                    child: FeatureMessage(
                      icon: AppIcons.error,
                      title: l10n.featuresSkillsReadFailed,
                      action: (l10n.commonRetry, () {
                        final load = widget.load();
                        setState(() {
                          _skills = load;
                        });
                      }),
                    ),
                  );
                }
                final skills = snapshot.requireData;
                if (skills.isEmpty) {
                  return SingleChildScrollView(
                    child: FeatureMessage(icon: AppIcons.skill, title: l10n.featuresSkillsEmpty),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: skills.length,
                  itemBuilder: (context, index) {
                    final skill = skills[index];
                    return ListPageRow(
                      title: '/${skill.name}',
                      subtitle: skill.description.isEmpty ? null : skill.description,
                      subtitleMaxLines: 2,
                      badge: skill.modelInvocable ? null : PluginBadge(l10n.featuresSkillManual),
                      chevron: false,
                      onTap: () => Navigator.of(context).pop(skill),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
