import { createFileRoute } from '@tanstack/react-router'
import { ComponentExample } from '@/components/component-example'

export const Route = createFileRoute('/')({
  component: Index,
})

function Index() {
  return (
    <div className="p-2">
      <h3>Welcome Home!</h3>
      <ComponentExample />
    </div>
  )
}