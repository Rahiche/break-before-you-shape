import 'dart:math';

// Chat messages for the demo, written for it: short and long, in the six languages
// of the paper's corpora, with some emoji (which the sidecar's font does not
// have, so those messages go to Flutter).
const _pools = {
  'en': [
    'Running late, be there in ten.', 'Did you see the office memo about the offsite?', 'Sure!',
    'I think the fluffy one is cuter, honestly.',
    'Can we move the call to 3:30? Traffic is awful today and I won\'t make it back in time.',
    'Ava said the Wi-Fi password changed again, it\'s on the fridge.', 'Thanks!', 'Fine by me.',
    'The final draft is attached; please check sections 2.1 and 4 before Friday.', 'Where did you park?',
    'Tickets are €45 each, or €80 for two.', 'Happy birthday! Hope it\'s a great one.',
    'Let\'s order pizza tonight; I\'ll pay for the drinks.', 'Who\'s bringing the projector for tomorrow\'s workshop?',
    'Totally forgot, sorry. Sending it now.', 'The flight was delayed by two hours, so we\'re still at the airport.',
    'Yes, that works. Shall I book a table for six?', 'Ok', 'Just finished the first draft of the report.',
    'Remember to water the plants while I\'m away (the fern needs it twice a week).',
  ],
  'de': [
    'Bin gleich da!', 'Kannst du bitte Brot und Käse mitbringen?', 'Das Meeting wurde auf Donnerstag verschoben.',
    'Grüße aus Zürich, das Wetter ist großartig.', 'Hast du die Rechnung schon bezahlt?', 'Alles klar, bis später.',
    'Der Zug hat wieder Verspätung, ich melde mich, wenn ich ankomme.', 'Danke für die schnelle Antwort!',
    'Wollen wir am Wochenende wandern gehen? Die Aussicht vom Gipfel soll fantastisch sein.',
  ],
  'fr': [
    'J’arrive dans cinq minutes.', 'On se retrouve devant le café ?', 'C’est noté, merci beaucoup !',
    'Le train a encore du retard, désolé.', 'Tu as vu le dernier épisode ?', 'Bonne idée, je réserve pour vendredi.',
    'Je t’envoie les photos de la soirée dès que je rentre à la maison.', 'Pas de souci, à demain.',
  ],
  'ru': [
    'Буду через десять минут.', 'Ты уже купил билеты?', 'Спасибо, всё получилось!',
    'Давай созвонимся вечером, если будет время.', 'Я на месте, жду у входа.',
    'Отправил тебе документы на почту, посмотри, пожалуйста, до обеда.',
  ],
  'uk': [
    'Дякую, до зустрічі!', 'Ти вже в Києві?', 'Зустрінемося біля метро о сьомій.', 'Чудово, тоді до завтра.',
    'Я трохи запізнюся, почніть без мене.',
  ],
  'el': [
    'Έρχομαι σε λίγο.', 'Ευχαριστώ πολύ!', 'Τα λέμε αύριο στο γραφείο.', 'Πού είσαι; Σε περιμένουμε ήδη.',
    'Έστειλα τα αρχεία, πες μου αν χρειάζεσαι κάτι άλλο.',
  ],
  'emoji': ['Congrats 🎉', 'On my way 🚗', 'Love it ❤️', '😂😂', 'See you there 👋'],
};

/// [count] messages, the same every run.
List<String> chatMessages(int count, {int seed = 42}) {
  final rnd = Random(seed);
  final langs = ['en', 'en', 'en', 'de', 'fr', 'ru', 'uk', 'el'];
  return [
    for (var i = 0; i < count; i++)
      () {
        if (rnd.nextInt(20) == 0) return _pools['emoji']![rnd.nextInt(5)];
        final pool = _pools[langs[rnd.nextInt(langs.length)]]!;
        // Mostly one or two sentences; now and then a long message.
        final n = rnd.nextInt(8) == 0 ? 4 + rnd.nextInt(6) : 1 + rnd.nextInt(2);
        return [for (var k = 0; k < n; k++) pool[rnd.nextInt(pool.length)]].join(' ');
      }()
  ];
}
