"""Invented meetings with known commitments, for LoRA training of the to-do extraction pass.

Each example = one transcript part (as the engine gives it to the model) + the exact answer the
ACTIONS_PROMPT asks for: one JSON object per real commitment, nothing for the traps (done in the
meeting, already done, questions, wishes, hypotheticals, availability, leaving the call…).

    python gen.py OUT_DIR N_TRAIN N_VALID SEED
"""
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
import meetscribe.summarize as sm  # noqa: E402

NAMES = ["Sarah", "Tom", "Aisha", "Marc", "Léa", "Jake", "Priya", "Oliver", "Nadia", "Hugo", "Emma", "Ken",
         "Camille", "Yusuf", "Chloe", "Ben", "Fatima", "Lucas", "Mei", "Andy", "Selen", "Diego", "Inès", "Paul",
         "Zoe", "Raj", "Clara", "Simon", "Julia", "Omar"]

# (english task said, english task for the answer, french said, french answer)
TASKS = [
    ("send the updated deck to the client", "send the updated deck to the client",
     "envoyer la présentation mise à jour au client", "envoyer la présentation mise à jour au client"),
    ("book the meeting room for the workshop", "book the meeting room for the workshop",
     "réserver la salle pour l'atelier", "réserver la salle pour l'atelier"),
    ("call the supplier about the missing parts", "call the supplier about the missing parts",
     "appeler le fournisseur pour les pièces manquantes", "appeler le fournisseur pour les pièces manquantes"),
    ("write up the test plan", "write up the test plan", "rédiger le plan de test", "rédiger le plan de test"),
    ("update the budget spreadsheet", "update the budget spreadsheet",
     "mettre à jour le tableau du budget", "mettre à jour le tableau du budget"),
    ("check the contract with legal", "check the contract with legal",
     "vérifier le contrat avec le juridique", "vérifier le contrat avec le juridique"),
    ("order ten more bearings", "order ten more bearings",
     "commander dix roulements de plus", "commander dix roulements de plus"),
    ("set up the staging server", "set up the staging server",
     "installer le serveur de préproduction", "installer le serveur de préproduction"),
    ("share the survey results with the team", "share the survey results with the team",
     "partager les résultats du sondage avec l'équipe", "partager les résultats du sondage avec l'équipe"),
    ("ask IT for two more licences", "ask IT for two more licences",
     "demander deux licences de plus à l'informatique", "demander deux licences de plus à l'informatique"),
    ("prepare the onboarding checklist", "prepare the onboarding checklist",
     "préparer la checklist d'arrivée", "préparer la checklist d'arrivée"),
    ("follow up with the bank on the invoice", "follow up with the bank on the invoice",
     "relancer la banque pour la facture", "relancer la banque pour la facture"),
    ("draft the newsletter for November", "draft the November newsletter",
     "écrire le brouillon de la newsletter de novembre", "écrire le brouillon de la newsletter de novembre"),
    ("fix the login bug on Android", "fix the Android login bug",
     "corriger le bug de connexion sur Android", "corriger le bug de connexion sur Android"),
    ("review the pull request from the new intern", "review the new intern's pull request",
     "relire la pull request du stagiaire", "relire la pull request du stagiaire"),
    ("get a quote from the cleaning company", "get a quote from the cleaning company",
     "demander un devis à l'entreprise de nettoyage", "demander un devis à l'entreprise de nettoyage"),
    ("organise the team dinner", "organise the team dinner",
     "organiser le dîner d'équipe", "organiser le dîner d'équipe"),
    ("send the minutes to everyone", "send the minutes to everyone",
     "envoyer le compte rendu à tout le monde", "envoyer le compte rendu à tout le monde"),
    ("talk to the landlord about the heating", "talk to the landlord about the heating",
     "parler au propriétaire du chauffage", "parler au propriétaire du chauffage"),
    ("create the repair tickets in Odoo", "create the repair tickets in Odoo",
     "créer les tickets de réparation dans Odoo", "créer les tickets de réparation dans Odoo"),
    ("measure the warehouse shelves", "measure the warehouse shelves",
     "mesurer les étagères de l'entrepôt", "mesurer les étagères de l'entrepôt"),
    ("renew the domain name", "renew the domain name", "renouveler le nom de domaine", "renouveler le nom de domaine"),
    ("translate the user guide into Spanish", "translate the user guide into Spanish",
     "traduire le guide utilisateur en espagnol", "traduire le guide utilisateur en espagnol"),
    ("run the load test on the new API", "run the load test on the new API",
     "lancer le test de charge sur la nouvelle API", "lancer le test de charge sur la nouvelle API"),
    ("invite the client to the demo", "invite the client to the demo",
     "inviter le client à la démo", "inviter le client à la démo"),
    ("compare the three insurance offers", "compare the three insurance offers",
     "comparer les trois offres d'assurance", "comparer les trois offres d'assurance"),
    ("clean up the shared drive", "clean up the shared drive", "faire le ménage dans le drive partagé",
     "faire le ménage dans le drive partagé"),
    ("write the job ad for the designer role", "write the job ad for the designer role",
     "rédiger l'annonce pour le poste de designer", "rédiger l'annonce pour le poste de designer"),
    ("send the spare springs to Jeddah", "send the spare springs to Jeddah",
     "envoyer les ressorts de rechange à Djeddah", "envoyer les ressorts de rechange à Djeddah"),
    ("check the stock of yellow caps", "check the stock of yellow caps",
     "vérifier le stock de capuchons jaunes", "vérifier le stock de capuchons jaunes"),
    ("ping Kiara about the vacuum motor", "ask Kiara about the vacuum motor",
     "relancer Kiara pour le moteur d'aspiration", "relancer Kiara pour le moteur d'aspiration"),
    ("put together the pricing proposal", "prepare the pricing proposal",
     "préparer la proposition de prix", "préparer la proposition de prix"),
    ("schedule the security audit", "schedule the security audit",
     "planifier l'audit de sécurité", "planifier l'audit de sécurité"),
    ("record a short video of the demo", "record a short demo video",
     "enregistrer une petite vidéo de la démo", "enregistrer une petite vidéo de la démo"),
]

DUES = [("by Friday", "Friday", "d'ici vendredi", "vendredi"), ("tomorrow", "tomorrow", "demain", "demain"),
        ("next week", "next week", "la semaine prochaine", "la semaine prochaine"),
        ("before the 14th", "before the 14th", "avant le 14", "avant le 14"),
        ("by end of day", "end of day", "avant ce soir", "ce soir"),
        ("on Monday", "Monday", "lundi", "lundi"), ("by the end of the month", "end of the month",
                                                     "d'ici la fin du mois", "fin du mois")]

TOPICS_EN = [
    "The numbers for October look a bit better than last month, around twelve percent up.",
    "We had three tickets from the airport site again, mostly about the wheels.",
    "I think the main issue is that nobody owns the process end to end.",
    "The client seemed happy with the first version, but they want more detail on costs.",
    "Honestly the old dashboard is fine for now, it does what we need.",
    "The shipment arrived on Tuesday, all five boxes, but one carton was damaged.",
    "We're still waiting for the final quote, they said it should come soon.",
    "Last time we tried that it took almost two months, so let's be realistic.",
    "The new version has a brighter screen and a slightly louder motor.",
    "From what I've seen, the team is quite stretched this month.",
    "The pilot site has around thirty-five cameras, so it's a small one.",
    "Yeah, that makes sense to me.", "Okay, cool.", "Right, I see.", "Mm-hmm.",
    "That's a good point, actually.", "I'm not sure about that, to be honest.",
    "So the main risk is the delivery date slipping again.",
    "Marketing wants the launch before Christmas if possible.",
    "The support queue went down to about forty open tickets.",
]
TOPICS_FR = [
    "Les chiffres d'octobre sont un peu meilleurs que le mois dernier, environ douze pour cent de plus.",
    "On a encore eu trois tickets du site de l'aéroport, surtout pour les roues.",
    "Je pense que le vrai problème, c'est que personne ne porte le processus de bout en bout.",
    "Le client avait l'air content de la première version, mais il veut plus de détails sur les coûts.",
    "Honnêtement l'ancien tableau de bord suffit pour l'instant.",
    "La livraison est arrivée mardi, les cinq cartons, mais un était abîmé.",
    "On attend toujours le devis final, ils ont dit que ça arrivait bientôt.",
    "La dernière fois qu'on a essayé, ça a pris presque deux mois.",
    "Oui, ça me paraît logique.", "D'accord.", "Ok, je vois.", "Hmm hmm.",
    "C'est un bon point, en fait.", "Je ne suis pas sûr, honnêtement.",
    "Le principal risque, c'est que la date de livraison glisse encore.",
    "Le marketing voudrait lancer avant Noël si possible.",
    "La file du support est descendue à une quarantaine de tickets ouverts.",
]

# Traps: sentences that look like commitments but are not (no answer line).
TRAPS_EN = [
    "Let me share my screen, can everyone see it?", "I'll give you an example: the wheels last month.",
    "Let me just check the list. Yes, it's here.", "I'll leave you guys to it, I have another call.",
    "I'm going to jump off, I've got a hard stop.", "I already sent the invoice this morning.",
    "I did that yesterday, it's done.", "I just sent the list of suppliers in the chat.",
    "Is that the Berlin office or the Paris one?", "Who was in charge of that last time?",
    "We should probably review the pricing at some point.", "It would be good to have a template for that.",
    "If the client agrees, we could run a pilot in January.", "Maybe we can look at that later in the year.",
    "I'll be on holiday next week, back on the 10th.", "I'll be busy with the trade show all Thursday.",
    "I'll put the one up that I have, it may not be the latest.", "Let me think about it for a second.",
    "I can't remember who ordered it.", "I'll start with the numbers, if that's okay.",
    "We already fixed that in the last release.", "I've forwarded it to you over the weekend.",
    "I'll leave that to you guys, you know it better.", "Let me pull up the spreadsheet.",
]
TRAPS_FR = [
    "Je partage mon écran, vous voyez bien ?", "Je vous donne un exemple : les roues le mois dernier.",
    "Attends, je regarde la liste. Oui, c'est là.", "Je vous laisse, j'ai un autre appel.",
    "J'ai déjà envoyé la facture ce matin.", "Je l'ai fait hier, c'est bon.",
    "C'est le bureau de Berlin ou celui de Paris ?", "Qui s'en occupait la dernière fois ?",
    "On devrait sans doute revoir les prix un jour.", "Ce serait bien d'avoir un modèle pour ça.",
    "Si le client est d'accord, on pourrait faire un pilote en janvier.",
    "Je serai en congé la semaine prochaine, je reviens le 10.", "Je commence par les chiffres, si ça vous va.",
    "On a déjà corrigé ça dans la dernière version.", "Laissez-moi réfléchir une seconde.",
]


def quote_of(line: str, task_said: str, rng) -> str:
    """5 to 8 words copied exactly from the line, around the task."""
    words = line.split()
    first = task_said.split()[0]
    i = next((k for k, w in enumerate(words) if w.strip(",.?!").lower() == first.lower()), 0)
    start = max(0, i - rng.randint(1, 3))
    return " ".join(words[start:start + rng.randint(5, 8)]).rstrip(",")


def commitment(rng, fr: bool, speaker: str, others: list[str]):
    """→ list of (speaker, text) lines and the answer item (or None for its time)."""
    task = rng.choice(TASKS)
    due = rng.choice(DUES) if rng.random() < 0.5 else None
    said, answer = (task[2], task[3]) if fr else (task[0], task[1])
    due_said = (due[2] if fr else due[0]) if due else ""
    due_answer = (due[2] if fr else due[0]) if due else ""
    kind = rng.random()
    if kind < 0.45:  # volunteered
        if fr:
            start = rng.choice(["Je vais", "Ok, je vais", "Je peux", "Moi, je vais", "Bon, je vais"])
        else:
            start = rng.choice(["I'll", "Okay, I'll", "I can", "I'm going to", "Yeah, I will", "Let me"])
        text = f"{start} {said}{' ' + due_said if due_said else ''}" + rng.choice([".", ", no problem.", " after the call." if not fr else ", pas de souci."])
        return [(speaker, text)], 0, dict(owner=speaker, task=answer, due=due_answer, said=said)
    if kind < 0.8:  # asked and accepted
        asked = rng.choice(others)
        if fr:
            ask = f"{asked}, tu peux {said}{' ' + due_said if due_said else ''} ?"
            yes = rng.choice(["Oui, pas de souci.", "Oui, je m'en occupe.", "Ok, ça marche.", "D'accord, je le fais."])
        else:
            ask = f"{asked}, can you {said}{' ' + due_said if due_said else ''}?"
            yes = rng.choice(["Sure, I'll do that.", "Yes, no problem.", "Yep, leave it with me.", "Okay, will do."])
        return [(speaker, ask), (asked, yes)], 0, dict(owner=asked, task=answer, due=due_answer, said=said)
    third = rng.choice(others)  # given to someone, said by another
    text = (f"Et {third} va {said}{' ' + due_said if due_said else ''}." if fr
            else f"And {third} will {said}{' ' + due_said if due_said else ''}.")
    return [(speaker, text)], 0, dict(owner=third, task=answer, due=due_answer, said=said)


def meeting(rng):
    fr = rng.random() < 0.3
    people = rng.sample(NAMES, rng.randint(3, 6))
    if rng.random() < 0.25:  # unnamed voices
        people[rng.randrange(1, len(people))] = f"Speaker {rng.randint(1, 9)}"
    topics, traps = (TOPICS_FR, TRAPS_FR) if fr else (TOPICS_EN, TRAPS_EN)
    lines, answers = [], []
    n_commit = rng.choice([0, 1, 2, 2, 3, 3, 4, 5])
    n_trap = rng.randint(1, 5)
    events = ["c"] * n_commit + ["t"] * n_trap + ["x"] * rng.randint(8, 20)
    rng.shuffle(events)
    used = set()
    for e in events:
        sp = rng.choice(people)
        if e == "x":
            lines.append((sp, " ".join(rng.sample(topics, rng.choice([1, 1, 2, 3])))))
        elif e == "t":
            lines.append((sp, rng.choice(traps)))
        else:
            got, _, item = commitment(rng, fr, sp, [p for p in people if p != sp])
            if item["said"] in used:
                continue
            if rng.random() < 0.4:  # said in the middle of a longer turn
                (s0, t0), rest = got[0], got[1:]
                extra = rng.choice(topics)
                got = [(s0, f"{extra} {t0}" if rng.random() < 0.5 else f"{t0} {extra}")] + rest
            used.add(item["said"])
            item["line"] = len(lines)
            lines.extend(got)
            answers.append(item)
    t = rng.randint(0, 3000)
    stamped = []
    for sp, text in lines:
        stamped.append((t, sp, text))
        t += rng.randint(3, 9) + len(text.split()) // 3
    fmt = lambda s: f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"
    transcript = "\n".join(f"[{fmt(t)}] {sp}: {text}" for t, sp, text in stamped)
    out = []
    for a in sorted(answers, key=lambda a: a["line"]):
        t, _, text = stamped[a["line"]]
        out.append(json.dumps({"owner": a["owner"], "task": a["task"], "due": a["due"], "at": fmt(t),
                               "quote": quote_of(text, a["said"], rng)}, ensure_ascii=False))
    lang = "French" if fr else "English"
    return {"messages": [
        {"role": "system", "content": sm.SYSTEM},
        {"role": "user", "content": f"Transcript:\n{transcript}\n\n---\n\n" + sm.ACTIONS_PROMPT.format(language=lang)},
        {"role": "assistant", "content": "\n".join(out)}]}


if __name__ == "__main__":
    out, n_train, n_valid, seed = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    rng = random.Random(seed)
    out.mkdir(parents=True, exist_ok=True)
    for name, n in (("train", n_train), ("valid", n_valid)):
        with open(out / f"{name}.jsonl", "w") as f:
            for _ in range(n):
                f.write(json.dumps(meeting(rng), ensure_ascii=False) + "\n")
