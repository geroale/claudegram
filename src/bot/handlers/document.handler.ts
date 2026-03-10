import { Context } from 'grammy';
import * as fs from 'fs';
import * as path from 'path';
import { config } from '../../config.js';
import { sendToAgent } from '../../claude/agent.js';
import { sessionManager } from '../../claude/session-manager.js';
import { messageSender } from '../../telegram/message-sender.js';
import { isDuplicate, markProcessed } from '../../telegram/deduplication.js';
import { isStaleMessage } from '../middleware/stale-filter.js';
import {
  queueRequest,
  isProcessing,
  getQueuePosition,
  setAbortController,
} from '../../claude/request-queue.js';
import { escapeMarkdownV2 as esc } from '../../telegram/markdown.js';
import { getStreamingMode } from './command.handler.js';
import { downloadFileSecure, getTelegramFileUrl } from '../../utils/download.js';
import { sanitizeError } from '../../utils/sanitize.js';
import { getSessionKeyFromCtx } from '../../utils/session-key.js';

const UPLOADS_DIR = '.claudegram/uploads';
const FILE_MAX_SIZE_MB = 20; // Telegram Bot API limit is 20MB for downloads

function sanitizeFileName(name: string): string {
  return path.basename(name).replace(/[^a-zA-Z0-9._-]/g, '_');
}

function ensureUploadsDir(projectDir: string): string {
  const dir = path.join(projectDir, UPLOADS_DIR);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

async function downloadTelegramFile(ctx: Context, fileId: string, destPath: string): Promise<string> {
  const file = await ctx.api.getFile(fileId);
  if (!file.file_path) {
    throw new Error('Telegram did not provide file_path for this file.');
  }

  const fileUrl = getTelegramFileUrl(config.TELEGRAM_BOT_TOKEN, file.file_path);
  await downloadFileSecure(fileUrl, destPath);

  return file.file_path;
}

async function handleSavedFile(
  ctx: Context,
  savedPath: string,
  originalName: string,
  mimeType: string | undefined,
  caption?: string
): Promise<void> {
  const keyInfo = getSessionKeyFromCtx(ctx);
  if (!keyInfo) return;
  const { sessionKey } = keyInfo;

  const session = sessionManager.getSession(sessionKey);
  if (!session) return;

  const relativePath = path.relative(session.workingDirectory, savedPath);

  const captionText = caption?.trim();
  const noteLines = [
    'User uploaded a file to the project.',
    `File name: ${originalName}`,
    `MIME type: ${mimeType || 'unknown'}`,
    `Saved at: ${savedPath}`,
    `Relative path: ${relativePath}`,
    captionText ? `Caption: "${captionText}"` : 'Caption: (none)',
    'If the caption includes a question or request about the file, answer it. Otherwise, acknowledge the file was received and ask what they would like to do with it.',
    'You can read and inspect the file with your tools as needed.',
  ];

  const agentPrompt = noteLines.join('\n');

  if (isProcessing(sessionKey)) {
    const position = getQueuePosition(sessionKey) + 1;
    await ctx.reply(`\u23F3 Queued \(position ${position}\)`, { parse_mode: 'MarkdownV2' });
  }

  await queueRequest(sessionKey, agentPrompt, async () => {
    if (getStreamingMode() === 'streaming') {
      await messageSender.startStreaming(ctx);

      const abortController = new AbortController();
      setAbortController(sessionKey, abortController);

      try {
        const response = await sendToAgent(sessionKey, agentPrompt, {
          onProgress: (progressText) => {
            messageSender.updateStream(ctx, progressText);
          },
          abortController,
        });

        await messageSender.finishStreaming(ctx, response.text);
      } catch (error) {
        await messageSender.cancelStreaming(ctx);
        throw error;
      }
    } else {
      await ctx.replyWithChatAction('typing');
      const abortController = new AbortController();
      setAbortController(sessionKey, abortController);

      const response = await sendToAgent(sessionKey, agentPrompt, { abortController });
      await messageSender.sendMessage(ctx, response.text);
    }
  });
}

export async function handleDocument(ctx: Context): Promise<void> {
  const keyInfo = getSessionKeyFromCtx(ctx);
  const messageId = ctx.message?.message_id;
  const messageDate = ctx.message?.date;
  const document = ctx.message?.document;

  if (!keyInfo || !messageId || !messageDate || !document) return;
  const { sessionKey } = keyInfo;

  if (isStaleMessage(messageDate)) {
    console.log(`[Document] Ignoring stale document ${messageId}`);
    return;
  }
  if (isDuplicate(messageId)) {
    console.log(`[Document] Ignoring duplicate document ${messageId}`);
    return;
  }
  markProcessed(messageId);

  const session = sessionManager.getSession(sessionKey);
  if (!session) {
    await ctx.reply(
      '\u26A0\uFE0F No project set\\.\n\nIf the bot restarted, use `/continue` or `/resume` to restore your last session\\.\nOr use `/project` to open a project first\\.',
      { parse_mode: 'MarkdownV2' }
    );
    return;
  }

  const fileSizeBytes = document.file_size || 0;
  const fileSizeMB = fileSizeBytes / (1024 * 1024);

  if (fileSizeMB > FILE_MAX_SIZE_MB) {
    await ctx.reply(
      `\u274C File too large \(${esc(fileSizeMB.toFixed(1))}MB\)\.
\nTelegram Bot API supports files up to ${esc(String(FILE_MAX_SIZE_MB))}MB\.`,
      { parse_mode: 'MarkdownV2' }
    );
    return;
  }

  const uploadsDir = ensureUploadsDir(session.workingDirectory);
  const timestamp = Date.now();
  const originalName = document.file_name ? sanitizeFileName(document.file_name) : `file_${timestamp}_${document.file_unique_id}`;
  const destPath = path.join(uploadsDir, `${timestamp}_${originalName}`);

  try {
    await downloadTelegramFile(ctx, document.file_id, destPath);

    const stat = fs.statSync(destPath);
    if (!stat.size) {
      throw new Error('Downloaded file is empty.');
    }

    await handleSavedFile(ctx, destPath, originalName, document.mime_type, ctx.message?.caption);
  } catch (error) {
    const errorMessage = sanitizeError(error);
    console.error('[Document] Error:', errorMessage);
    await ctx.reply(`\u274C File error: ${esc(errorMessage)}`, { parse_mode: 'MarkdownV2' });
  }
}
