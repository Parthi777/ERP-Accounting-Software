import 'server-only';

/**
 * Typed application errors.
 *
 * Spec §55: never fail silently, and never show a user a raw technical message.
 * Each error carries a `userMessage` safe to render and a `status` for the HTTP
 * boundary; the technical detail stays in `message` for the server log.
 */

export type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'FORBIDDEN'
  | 'NOT_FOUND'
  | 'VALIDATION'
  | 'CONFLICT'
  | 'ACCOUNTING'
  | 'INVENTORY'
  | 'EXTERNAL_SERVICE'
  | 'NOT_CONFIGURED'
  | 'INTERNAL';

const STATUS_BY_CODE: Record<ErrorCode, number> = {
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  VALIDATION: 422,
  CONFLICT: 409,
  ACCOUNTING: 422,
  INVENTORY: 422,
  EXTERNAL_SERVICE: 502,
  NOT_CONFIGURED: 503,
  INTERNAL: 500,
};

export class AppError extends Error {
  readonly code: ErrorCode;
  readonly userMessage: string;
  readonly details?: Readonly<Record<string, unknown>>;

  constructor(
    code: ErrorCode,
    message: string,
    userMessage?: string,
    details?: Readonly<Record<string, unknown>>,
  ) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.userMessage = userMessage ?? message;
    this.details = details;
  }

  get status(): number {
    return STATUS_BY_CODE[this.code];
  }

  toResponseBody() {
    return {
      error: {
        code: this.code,
        message: this.userMessage,
        ...(this.details ? { details: this.details } : {}),
      },
    };
  }
}

export class UnauthenticatedError extends AppError {
  constructor(message = 'No active session.') {
    super('UNAUTHENTICATED', message, 'Please sign in to continue.');
    this.name = 'UnauthenticatedError';
  }
}

export class ForbiddenError extends AppError {
  constructor(permission: string) {
    super(
      'FORBIDDEN',
      `Missing permission: ${permission}`,
      'You do not have permission to perform this action.',
      { permission },
    );
    this.name = 'ForbiddenError';
  }
}

export class NotFoundError extends AppError {
  constructor(entity: string) {
    super('NOT_FOUND', `${entity} not found`, `${entity} could not be found.`);
    this.name = 'NotFoundError';
  }
}

export class ValidationError extends AppError {
  constructor(message: string, details?: Readonly<Record<string, unknown>>) {
    super('VALIDATION', message, message, details);
    this.name = 'ValidationError';
  }
}

export class NotConfiguredError extends AppError {
  constructor(what: string) {
    super(
      'NOT_CONFIGURED',
      `${what} is not configured.`,
      'The application is not fully configured yet. Please contact your administrator.',
    );
    this.name = 'NotConfiguredError';
  }
}

/** Normalises anything thrown into an AppError, so route handlers stay uniform. */
export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) {
    return error;
  }
  if (error instanceof Error) {
    return new AppError('INTERNAL', error.message, 'Something went wrong. Please try again.');
  }
  return new AppError('INTERNAL', String(error), 'Something went wrong. Please try again.');
}
