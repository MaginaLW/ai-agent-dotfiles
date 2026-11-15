---
name: multimodal-generation
description: Create, edit or check image, video, audio or music assets using only quota from the user's existing Google subscription. Use for media requests such as concept art, textures, sprites, clips, music or sound effects.
---

# Multimodal Generation

Spend nothing new by default. Use only quota the user's existing subscription already provides. Paid API use stays off unless the user enables it for the current task (see API channel).

## Choose the channel

Use the first option the current host really provides. Check what the host offers; don't assume a tool from another host.

1. **Built-in host tools.** If the host has its own image generation or editing tool or subagent, use it. Antigravity's image generator is one example; it uses the subscription. Read each result back with the host's vision or file reader.
2. **Subscription web apps run by the user.** For video, music, or anything the host can't make itself, write a generation brief (see below) and ask the user to run it in the signed-in Gemini app or Google Flow. Only operate the signed-in page yourself if all of these hold: the host has a built-in browser it allows you to use, the user is present, and the user has asked for it. The user signs in and completes any verification. Stop at CAPTCHA, bot-check, payment or plan-upgrade screens.
3. **Hand off.** If neither option is available (for example in a terminal coding agent), don't generate anything. Save the brief with the task output, tell the user which host or web app can run it, and verify the files when they come back.
4. **API channel (opt-in).** Use it only under the conditions below.

Never reverse-engineer private web endpoints. Never move browser cookies or session tokens into scripts. Never bypass CAPTCHA or bot checks. Never wrap a consumer subscription CLI inside another agent to borrow its quota. Never switch accounts, buy credits or set up billing for the user.

## API channel (opt-in only)

Use the Gemini API (Google AI Studio) or Vertex AI only when all of these hold for the current task:

- The user has explicitly turned it on for this task and stated a spending ceiling.
- Credentials come from the environment (`GEMINI_API_KEY` or application default credentials). Never write key values into files, logs, prompts or command lines that get recorded.
- Before each call, check the official model list and pricing page for current availability and price. Report the estimated cost and the running total, and stop before the ceiling would be passed. The monthly developer credit that comes with the subscription is used up first; after that, normal charges apply. Cloud budget alerts only send notices; they do not stop spending.
- Choose the smallest model, resolution and duration that still meet the brief. Make one call per approved item. Never retry a billable failure in a loop.

## Generation brief

Write a brief for every asset before you generate it. The same brief is what you hand off to the user.

- **Purpose:** where the asset will be used (for example a Unity sprite, a Blender texture or trailer music).
- **Prompt:** the prompt itself, things to avoid, and any reference inputs (project-relative paths).
- **Spec:**
  - Images: size, aspect ratio, transparency, seamless tiling.
  - Video: length, aspect ratio, frame rate.
  - Audio: length, format, sample rate, whether it must loop.
- **Output:** the target path and file name.
- **Acceptance:** the checks listed below that apply.

## Output conventions

- Follow the project's existing asset folders and naming. If the project has none, use `generated/<kind>/<yyyymmdd>-<slug>-<nn>.<ext>` and say so.
- Save a `<file>.prompt.md` next to each result. Record the channel, the model if the host shows it, the prompt and the date. Leave out account names, keys and machine-private paths.
- Don't commit large binary files unless the project's asset policy (for example Git LFS) covers them.

## Verify before reporting

- **Images:** read each image back. Check its size, transparency and tiling seams against the spec.
- **Video and audio:** if `ffprobe` is available, check duration, resolution, frame rate, codec, sample rate and channel count. If you can't watch or listen to the content, say so. Don't claim it is right.
- **Report:** say which channel you used, list the files, the checks you ran and the money spent (zero or the amount). Also list anything you didn't generate and why.
