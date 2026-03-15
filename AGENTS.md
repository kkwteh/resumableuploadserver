@USER_AGENTS.md

## Business Context
NavigateAI is a B2B SaaS that serves property managers and owners who work on portfolios of homes. We allow them to extract insights and build workflows on top of videos of their properties throughout their lifecycle. Our critical workflows today are quality control (implemented as checklists) and scoping (implemented as line items). Our system decomposes into three high-level parts:
1. Capture - our mobile app allows our customer's employees or their vendors to capture videos of homes at various points in a project lifecycle
2. Analysis - our offline (and soon online) AI pipelines process the frames + audio for the home, building up an index of data (what's happening in each frame, what rooms are shown when), and then using it to either answer questions, build up a scope of work, assess the status of previously scoped work, and more.
3. Consumption - our users can log in to review and edit this data, and also optionally integrate with our API

## Project: `app/` (Python Django API)
### Info
- We're using django 4.2, with ninja for routes.
- Older models have integer IDs. Newer models (subclassing NavigateModel directly) have IDs that are prefixed strings (specifically, a unique type that subclasses string per model, which can be accessed as ModelName.Id).

### Style - General
- Use the `*` operator to enforce keyword-only arguments for functions with many parameters, or parameters with similar types. [docs](https://docs.python.org/3/tutorial/controlflow.html#keyword-only-arguments)
- Prefer using the ContextualThreadPoolExecutor to a vanilla ThreadPoolExecutor.
- Prefer pydantic models over typed dicts, dataclasses, and named tuples, unless there is a strong reason otherwise.
- Prefer immutable types (tuples, frozensets, frozen pydantic models, frozen dataclasses) over mutable ones when mutability doesn't matter.
- When deciding on function definitions, prefer to be permissive on inputs (e.g. Sequence) and explicit on outputs (e.g. list)

### Style - Common LLM Mistakes
- Avoid getattr/hasattr - prefer to use better typed data models (generally Pydantic if serialization is needed, dataclasses otherwise).
- Put imports at the top of the file whenever possible, rather than doing inline imports.
  - Inline imports are only acceptable for: avoiding circular dependencies, optional dependencies that may not be installed, or imports only used in type checking (`if TYPE_CHECKING:`).
- Prefer pydantic models over typed dicts, dataclasses, and named tuples, unless there is a clear reason to do otherwise.
- Only leave comments where necessary to add clarity.

### Style - Annotations
- All new python files should use `# pyright: strict`
- This is unnecessary, do not do it: `from future import __annotations__`
- Importantly: try very hard to avoid using `Any` as a type, `cast`, or using `# pyright: ignore`, unless no better alternatives exist. You should always try to use correct types instead.
- Prefer to `# pyright: ignore[specificRule]` rather than blanket ignoring.
- If importing a function from a file that is not `# pyright: strict`, or some third party library, it is acceptable to `# pyright: ignore[theParticularError]`. For first party code, try to improve the typing first.
- Prefer modern python typing, e.g. | instead of Union, | None instead of Optional, dict instead of Dict, etc.
- When referencing IDs for models subclassing NavigateModel, prefer to annotate with the specific ModelName.Id type.

### Style - LLM Usage
Rules for writing prompts for LLMs:
- Use PromptRegistry to store the prompts
- Use BootstrapInfo to create the initial prompt in the database when the code is first executed. The tag of the BootstrapInfo must match the tag passed to the render call. To update an existing prompt, you'll need to also modify the tags to get it to run again (e.g. from "production-alpha" to "production-beta" or from {"production": "alpha"} to {"production": "beta"}).
- Use registry.load_and_render_with_overrides when possible, and accept a ModelOverrides from your caller when relevant.

Rules for executing requests:
- Use vertex.py if we need to inject a video file or audio file into the prompt, otherwise ai_utils.py or openai_utils.py which end up calling the openai sdk (including for gemini and vertex models).
- Pass model_config instead of raw parameters like `model` and `temperature` (when covered by ModelConfig)
- Use structured outputs via pydantic models. Make sure to include the expected response format in the prompt if using a gemini model with openai SDK, because the parameter is ignored in that case.
- For models that support temperatures, prefer a low (0.1) temperature for most tasks.
- If there are non-pydantic validations to apply, make sure to validate the output and retry if needed. Consider whether it makes sense to have stricter validations on the initial attempts, and do some slight coercion on the last attempt.
- Don't use complex model_validates on pydantic models (this is a legacy approach), instead write separate validation functions to be executed inside your retry loops if complex validation is needed.

Examples:
- See video_line_item_row.py for an example using vertex client with best practices (no retry loop needed here).
- See video_issue_justifier.py for an example using the openai sdk with a retry loop (except not handling overrides properly)

### Style - Testing
- For django models, generally prefer to create models via the fixtures in `from test_utils import fixtures`. If there is appropriate fixture, add one (or occasionally create them directly in the test, if adding a fixture seems inappropriate). Never mock django models.
- For more integration-style tests, LLM calls can be mocked with `llm_mocks.py`, either `mock_get_chat_completion_with_request_log` or `mock_vertex_completion`.
- Tests should extend `from django.test import TestCase`, or if they need to access the database from inside a ThreadPool, `TransactionTestCase`.
- Prefer slightly more integration style tests than unit style tests in general, but use your judgement.
- Name test files with a `_test.py` suffix.

### Style - Django Models
- Always subclass NavigateModel for new models, and define an appropriate unique ID prefix.
- Prefer using `LiteralTextField` over Django's `TextChoices`
- Prefix model attributes with an underscore when they are accessed primarily through an `@property`, but make sure to use db_column to keep the database column name free of underscores.
- Make sure to add type annotations for foreign key ID fields (if they are a foreign key, consider whether they should be annotated with int or TargetModel.Id, and whether it's nullable). E.g. `user = ...` -> also add `user_id: ...`
- Make sure to add reverse type annotations for one to many relationships, e.g. `"posts: Manager[Post]"`.
- All new models should have an organization_id foreign key if the data is owned by an organization.
- For OneToOneField, it's often useful to add a `some_model_maybe` method on the target class, which returns None on ObjectDoesNotExist.
- Instead of using boolean columns to represent if an event has happened, use a nullable datetime column to be populated with the time that event happened. Ex: Prefer expired_at (datetime) over is_expired (boolean)
- Instead of using boolean columns to represent the type of something, prefer an enum (`LiteralTextField`) which future-proofs additing additional options. Ex: Prefer adding column `object_type` (`LiteralTextField` with 2 options) over adding a boolean column `is_special_type`.

### Style - Routes
- **Structure**: APIs should be added to the appropriate folder (`api` for normal product routes, `api/admin` for admin-only, `api/mobile` for mobile, or `app/api_external` for external API), and then must be mounted in the appropriate `api.py` file. When working on the external API, also read `app/api_external/AGENTS.md` for external-API-specific conventions. Name the python file after the resource noun, singular. The routes themselves should avoid having verbs unless it doesn't fit into typical REST verbs, but the function names should have verbs, e.g. `@router.get("/video") def get_video`.
- **Requests and responses**: Define request/response models with `ninja.Schema`, using `OperationSuccessSchema` for empty success responses.
- **Auth and permissions**: For normal user routes, enforce resource-level checks with `@require_rule(predicate, "param_name")`, `@requires_rule(is_staff)`, etc. and scope DB reads when possible to `request.auth_ctx.organization` for non-staff. Admin routes are already by default restricted to staff only.
- **Performance**: Use `select_related`/`prefetch_related` to avoid N+1.
- **Pagination**: For list APIs that can have very large responses (>> 100 items), provide pagination using a ninja FilterSchema subclass, `per_page`, `page`, `sort` and a Paginator.
- For operations that would take over a few seconds (e.g. LLM calls to larger models with lots of context), consider spawning a Temporal workflow and returning the ID, and then using `/async_operation/result` via `useAsyncOperation` to poll.

### Logging
- Use our internal logger:
  - You can import the logger as `from utils.logging import logger`.
  - An Exception can be passed to both `.warning(..., exception=e)` or `.error(..., exception=e)`
  - Use `logger.contextualize` to bind variables for an entire block when appropriate.
  - Do not include auth_ctx in logger fields. It is added automatically in middleware.
- To log timing and success for critical methods, you can use the `@command()` decorator.
  - If the inputs and results are large, see the docstring about passing a log_input or log_result function, and grep if needed to look at examples.
- Avoid putting highly variable data into log messages (booleans may be okay, IDs aren't) - instead use structured fields:
  - Bad: `logger.info(f"Video {video.id} failed")`
  - Good: `logger.info("Video failed", video_id=video.id)`
- Do not end log messages with periods (avoid trailing punctuation)
- Avoid punctuation in log messages that interfere with grep searches, such as parentheses `()`, backslashes `\`, or other special characters

### Execution - Testing
- Use `mise -C app test --keepdb <file OR directory OR Python module path>` to run tests.
  - If the db is in a bad state or migrations need to run, use `mise -C app test --noinput ...` instead
  - Use `--parallel` for multiple tests.

### Execution
Run these commands after major code changes:
- Run the formatter with: Use `mise -C app format`
- Run typechecking with `mise -C app pyright`

### Execution - Django Migrations
- First make your changes to the Django models, and only then use `mise -C app makemigrations` to generate the migration.

## Project: `web_client/` (Typescript/React Web Frontend)

The rules defined within this section pertain to the following folders and all files contained within, referred to as the `web client` overall: `./web_client`

### Architecture
- The web client uses the following libraries and frameworks: Next.js v15, React v18, TypeScript v5, Tailwind v3, Zustand, and various libraries from Radix UI and TanStack
- The web client decomposes into two sets of routes with some separate and shared components, `admin` routes and non-`admin` ("product") routes.

### TypeScript
- Prefer `type` aliases over `interface`, with the exception of extensibility or declaration merging
  ```typescript
  // Avoid unless extending or merging
  interface User {
    id: string;
    name: string;
  }

  // OK
  type User = {
    id: string;
    name: string;
  };

  // OK when extensibility is needed
  interface BaseProps {
    className?: string;
  }
  interface ButtonProps extends BaseProps {
    onClick: () => void;
  }
  ```

### React / Next.js
- Refer to the React v18 documentation for common best practices: [docs](https://18.react.dev/reference/react)
- Components should be wrapped in a `memo` by default
  ```typescript
  import { memo } from "react";

  export const TestComponent = memo(function TestComponent() {
    // ...contents
  });
  TestComponent.displayName = "TestComponent";
  ```
- Trivial computations (simple arithmetic, accessing a property, simple lookups) should not be wrapped in `useMemo`
- Contexts & Providers should rarely be used outside of base components, and should never contain heavy logic
- Zustand stores should be scoped to specific flows or pages, not used as application-wide global stores
- Use dynamic imports for heavy components: `const Heavy = dynamic(() => import('./Heavy'))`

### File system & naming
- Prefer `PascalCase` for components, `camelCase` for utilities and functions, and `kebab-case` for folders

### Imports
- Prefer path aliases as defined in `tsconfig.json` over local imports, such as:
  - `@/` for src root
  - `@navigateai/web-api` for generated API hooks
- Biome handles sorting and ordering of all imports on lint and commit

### Custom Icons
- Custom icons that follows the Lucide icon guidelines should be added to `src/components/icons`
- Custom icons that pertain to NavigateAI's branding should be added to `src/brand`
- Custom icons that use `id=""` should use `useId` from `react`

### Design system
- When adding commonly used frontend components such as links, checkboxes, or buttons, look for them in these places. Earlier items in this ordering take precedence. Only when there is no reasonable alternative, proceed to try the next place. You should strongly advise to create a design system component if the component seems generic and reusable.
  - Design system components at `@/design-system`
  - ShadCN or Radix UI components from `@/components/ui`
  - Standard HTML (only use as a last resort)
- Tailwind should prefer the custom color scheme and extensions over built-in colors and typography sizing
  - Refer to `tailwind.config.ts` and the utils/plugins found within `src/lib/tailwind`
  - Example: `bg-gray-0` over `bg-white` and `body-12` over `text-xs`
  - Use `body-14` for small text, `body-16` for regular text, and larger body sizes otherwise.
  - Use `heading-16` for small headers, and `heading-20` or `heading-24` for larger ones, generally with `font-medium`.
  - For normal text colors, use `text-gray-0` up through `text-gray-130`. Normal body font is `text-gray-130`.

### API
- TanStack Query is the primary means of interacting with the API, with hooks generated via Orval and found within `@navigateai/web-api`
- Ensure the following for all API calls:
  - Reasonable caching: for typically stable responses, prefer invalidating rather than always fetching (configure `staleTime`)
  - Only enabled when necessary (configure `enabled` option)
  - Disable retries for calls that will likely not resolve on retry (e.g., `retry: false`, `retryOnMount: false`)
- Never process API responses and store them in a separate state store to pass around; instead, use TanStack Query as the store itself
  - For derived data, use `useMemo` or create selector functions that operate on query data directly from TanStack Query

### Execution - Frontend API Binding Generation
To update the typescript openapi client bindings after updating python route definitions, run this from the `web_client` directory: `mise generate-openapi`.

Note that API bindings are generated as `useScopingGetScopingPolicyTemplate` and importable from `@navigateai/web-api` -- where `Scoping` is the name the router is mounted with (generally the name of the file it is defined in), and the remainder is the name of the python API function. There will also be an additional `admin` prefix for admin routes.

## Project: `mobile-capture-2/` (React Native Mobile App)

### Execution - Mobile API Binding Generation
To update the typescript openapi client bindings after updating python route definitions, run this from the `mobile-capture-2` directory: `mise generate-openapi`.

## Global: TypeScript
- Avoid using `any`, prefer `unknown` and strict generics
  ```typescript
  // Avoid - loses all type safety
  function fetchUserData(userId: any): Promise<any> {
    return api.get(`/users/${userId}`);
  }
  const user = await fetchUserData("123");
  user.nonExistentMethod(); // No type error!

  // OK - use generics when the type is known by the caller
  function fetchData<T>(endpoint: string): Promise<T> {
    return api.get(endpoint);
  }
  type User = { id: string; name: string; email: string };
  const user = await fetchData<User>("/users/123");
  user.email; // ✓ Type-safe

  // OK - use unknown when type is truly dynamic and needs runtime validation
  function parseApiResponse(response: unknown): User {
    if (
      typeof response === "object" &&
      response !== null &&
      "id" in response &&
      "name" in response &&
      "email" in response
    ) {
      return response as User;
    }
    throw new Error("Invalid user response");
  }
  ```

- Prefer type guards for runtime type validation when necessary
  ```typescript
  // Avoid
  function handleResponse(response: unknown) {
    const data = response as ApiResponse;
    return data.result;
  }

  // OK
  function isApiResponse(value: unknown): value is ApiResponse {
    return (
      typeof value === "object" &&
      value !== null &&
      "result" in value
    );
  }

  function handleResponse(response: unknown) {
    if (isApiResponse(response)) {
      return response.result;
    }
    throw new Error("Invalid response");
  }
  ```


## Project: `mobile-capture-2/` (TypeScript/ReactNative mobile client, with some native bindings for ios & Android)

Read mobile-capture-2/AGENTS.md for more detail when working with the mobile client.
