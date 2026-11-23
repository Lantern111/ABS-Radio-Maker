// Creates the ABS Radio Maker feedback form in your Google account, for bug reports and suggestions, and emails each
// one to that account's Gmail.
//
// 1. Go to https://script.google.com, click New project, and replace the code there with this file.
// 2. Choose setUp in the toolbar, click Run, and allow the permissions it asks for.
// 3. Copy the three links from the Execution log. Running it again shows the same links without making a second form.
//
// Your address is looked up when a report arrives, so it doesn't appear in this file or on the form.

const BUG = '버그 신고 / Bug report';
const SUGGESTION = '개선 요청 / Suggestion';

function setUp() {
  const properties = PropertiesService.getScriptProperties();

  if (!properties.getProperty('formLink')) {
    const form = FormApp.create('ABS Radio Maker 제보 / Feedback', true);
    form.setDescription(
      '문제가 생겼거나, 이렇게 바뀌면 좋겠다 싶은 점을 알려 주세요. 계정이나 이름은 필요 없습니다.\n' +
      'Tell us what went wrong, or what you\'d like changed. You don\'t need an account or a name.'
    );
    form.setConfirmationMessage('보내 주셔서 감사합니다. / Thanks for letting us know.');

    const kind = form.addMultipleChoiceItem()
      .setTitle('어떤 제보인가요? / What is this about?')
      .setChoiceValues([BUG, SUGGESTION])
      .setRequired(true);
    const details = form.addParagraphTextItem()
      .setTitle('내용 / Details')
      .setHelpText(
        '버그라면 무엇이 잘못됐는지, 개선 요청이라면 어떻게 바뀌면 좋을지 적어 주세요.\n' +
        'For a bug, what went wrong. For a suggestion, what you\'d like changed.'
      )
      .setRequired(true);
    form.addParagraphTextItem()
      .setTitle('어떻게 하면 다시 생기나요? / How can it be reproduced?')
      .setHelpText('버그일 때만 적어 주세요. / Only for bugs.');
    const appVersion = form.addTextItem()
      .setTitle('앱 버전 / App version');
    const macOSVersion = form.addTextItem()
      .setTitle('macOS 버전 / macOS version');
    const mac = form.addTextItem()
      .setTitle('Mac 종류 / Mac');
    form.addTextItem()
      .setTitle('답장 받을 이메일 / Email for a reply')
      .setHelpText('답장이 필요할 때만 적어 주세요. / Only if you\'d like a reply.')
      .setValidation(FormApp.createTextValidation().requireTextIsEmail().build());

    // The app swaps these placeholders for the real details when it opens the form.
    function prefilled(choice) {
      return form.createResponse()
        .withItemResponse(kind.createResponse(choice))
        .withItemResponse(details.createResponse('DETAILS'))
        .withItemResponse(appVersion.createResponse('APP_VERSION'))
        .withItemResponse(macOSVersion.createResponse('MACOS_VERSION'))
        .withItemResponse(mac.createResponse('MAC_TYPE'))
        .toPrefilledUrl();
    }

    ScriptApp.newTrigger('sendReportToGmail').forForm(form).onFormSubmit().create();

    properties.setProperties({
      formLink: form.getPublishedUrl(),
      bugLink: prefilled(BUG),
      suggestionLink: prefilled(SUGGESTION),
    });
  }

  Logger.log('Form link: ' + properties.getProperty('formLink'));
  Logger.log('Bug report link: ' + properties.getProperty('bugLink'));
  Logger.log('Suggestion link: ' + properties.getProperty('suggestionLink'));
}

function sendReportToGmail(event) {
  const answers = event.response.getItemResponses().filter(function (answer) { return answer.getResponse(); });
  const kind = answers.length > 0 && answers[0].getResponse() === SUGGESTION ? '개선 요청' : '버그 신고';
  const report = answers
    .map(function (answer) { return answer.getItem().getTitle() + '\n' + answer.getResponse(); })
    .join('\n\n');

  MailApp.sendEmail(Session.getEffectiveUser().getEmail(), 'ABS Radio Maker ' + kind, report);
}
