/// Future adapter boundary. No network calls or secrets in stage 1.
enum AiAction { summarize, explain, questions, tasks, dayPlan, answer }

class AiRequest {
  final AiAction action;
  final String explicitlySelectedText;
  final int maxOutputTokens;
  const AiRequest(
    this.action,
    this.explicitlySelectedText, {
    this.maxOutputTokens = 1024,
  });
}

abstract interface class AiProvider {
  bool get connected;
  Future<String> propose(AiRequest request);
  void cancel();
}
